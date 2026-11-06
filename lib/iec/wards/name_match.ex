defmodule Iec.Wards.NameMatch do
  @moduledoc """
  Fuzzy matching of what someone types against a municipality: its name and code
  ("TSH - City of Tshwane"), and the names people use for the places in it ("Pretoria").

  Every typed word must match some word of the name, best first: the whole word, its
  start (so a name matches while it is still being typed), a part of it, or a word that
  is close to it (a typo: "tswane", "johanesburg"). Accents and case are ignored.

  A match carries the parts of the name to highlight, as `segments`:
  `[{text, matched?}]`, which put together give the name back.
  """

  # Typed words that narrow nothing down.
  @ignored ~w(of the municipality municipal local metro metropolitan district city)

  # How close a misspelt word must be (Jaro similarity) to count.
  @typo_threshold 0.86

  # The places people search by, mapped to a word of their municipality's name. The IEC
  # names wards by municipality only, so these cover the big cities and towns whose
  # names differ from their municipality's.
  @places %{
    "tshwane" => ["pretoria", "centurion", "soshanguve", "mamelodi", "atteridgeville"],
    "johannesburg" => ["joburg", "jozi", "soweto", "sandton", "randburg", "roodepoort"],
    "ethekwini" => ["durban", "umlazi", "pinetown", "chatsworth", "umhlanga"],
    "ekurhuleni" => [
      "germiston",
      "benoni",
      "boksburg",
      "kempton park",
      "springs",
      "alberton",
      "tembisa"
    ],
    "nelson" => ["gqeberha", "port elizabeth", "uitenhage", "kariega"],
    "buffalo" => ["east london", "mdantsane", "qonce", "king william's town"],
    "mangaung" => ["bloemfontein", "bloem", "botshabelo"],
    "cape town" => ["khayelitsha", "mitchells plain", "bellville"],
    "mbombela" => ["nelspruit"],
    "msunduzi" => ["pietermaritzburg", "pmb"],
    "sol plaatje" => ["kimberley"],
    "dawid kruiper" => ["upington"],
    "emfuleni" => ["vereeniging", "vanderbijlpark", "sebokeng"],
    "mogale" => ["krugersdorp"],
    "matjhabeng" => ["welkom"],
    "jb marks" => ["potchefstroom", "potch"],
    "matlosana" => ["klerksdorp"],
    "mafikeng" => ["mahikeng", "mmabatho"],
    "umhlathuze" => ["richards bay", "empangeni"],
    "alfred duma" => ["ladysmith"],
    "king sabata" => ["mthatha", "umtata"],
    "drakenstein" => ["paarl", "wellington"],
    "breede valley" => ["worcester"],
    "overstrand" => ["hermanus"],
    "bitou" => ["plettenberg bay", "plett"],
    "makana" => ["makhanda", "grahamstown"],
    "kouga" => ["jeffreys bay", "humansdorp"],
    "polokwane" => ["pietersburg"],
    "steve tshwete" => ["middelburg"],
    "govan mbeki" => ["secunda"],
    "rustenburg" => ["tlhabane"],
    "midvaal" => ["meyerton"],
    "stellenbosch" => ["franschhoek"]
  }

  @doc """
  The typed words worth matching, normalised: lower case, no accents, no words that
  narrow nothing down. Numbers are left to the caller.
  """
  def words(text) do
    text
    |> normalise()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @ignored))
  end

  @doc "Lower case, accents and punctuation dropped, words split by single spaces."
  def normalise(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/['’!.]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  # The places people know a municipality by (`@places`), from its name.
  defp places(name) do
    normalised = normalise(name)

    @places
    |> Enum.filter(fn {fragment, _places} -> String.contains?(normalised, fragment) end)
    |> Enum.flat_map(fn {_fragment, places} -> places end)
  end

  @doc """
  How well typed words (`words/1`) match a municipality name: nil when some word does not
  match, else `%{score, segments, place}` with a score from 0 to 1 and, when the match
  came through a place it holds ("Pretoria"), that place.
  """
  def match(_name, []), do: nil
  def match(name, words) when is_binary(name), do: match(prepare(name), words)

  def match(%{name: name} = prepared, words) do
    by_name = match_name(prepared, words)

    by_place =
      prepared.places
      |> Enum.map(fn {place, tokens} -> {place, match_tokens(tokens, words)} end)
      |> Enum.reject(fn {_place, result} -> is_nil(result) end)
      |> Enum.max_by(fn {_place, {score, _highlights}} -> score end, fn -> nil end)

    case {by_name, by_place} do
      {nil, nil} ->
        nil

      {%{score: score} = match, {_place, {place_score, _highlights}}} when score >= place_score ->
        match

      {_by_name, {place, {score, _highlights}}} ->
        %{score: score * 0.98, segments: [{name, false}], place: place}

      {match, nil} ->
        match
    end
  end

  @doc """
  A municipality's name made ready for matching once, for matching it many times: its
  parts (words and what lies between), its normalised words, and the places it holds
  (`@places`), with the first letters of all their words.
  """
  def prepare(name), do: prepare(name, places(name))

  @doc "A town or suburb's name made ready like `prepare/1`, with its own other names."
  def prepare_place(name, other_names), do: prepare(name, Enum.map(other_names, &normalise/1))

  defp prepare(name, other_names) do
    parts = Regex.split(~r/[\p{L}\p{N}]+/u, name, include_captures: true)
    tokens = for {part, index} <- Enum.with_index(parts), rem(index, 2) == 1, do: normalise(part)

    places =
      other_names
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&{&1, String.split(&1)})

    %{
      name: name,
      parts: parts,
      tokens: tokens,
      places: places,
      initials:
        (tokens ++ Enum.flat_map(places, &elem(&1, 1)))
        |> MapSet.new(&String.first/1)
    }
  end

  @doc """
  Whether a prepared name could match the words at all: each must start like one of its
  words. A cheap test before `match/2`, for long lists of names.
  """
  def possible?(%{initials: initials}, words),
    do: Enum.all?(words, &MapSet.member?(initials, String.first(&1)))

  # Matches the words against the name's own words, keeping what to highlight.
  defp match_name(%{parts: parts, tokens: tokens}, words) do
    case match_tokens(tokens, words) do
      nil ->
        nil

      {score, highlights} ->
        segments =
          parts
          |> Enum.with_index()
          |> Enum.flat_map(fn {part, index} ->
            case highlights[div(index, 2)] do
              {start, length} when rem(index, 2) == 1 -> split_part(part, start, length)
              _plain -> [{part, false}]
            end
          end)
          |> Enum.reject(fn {text, _matched} -> text == "" end)
          |> Enum.chunk_by(&elem(&1, 1))
          |> Enum.map(fn [{_text, matched} | _rest] = chunk ->
            {Enum.map_join(chunk, &elem(&1, 0)), matched}
          end)

        %{score: score, segments: segments, place: nil}
    end
  end

  defp split_part(part, start, length) do
    [
      {String.slice(part, 0, start), false},
      {String.slice(part, start, length), true},
      {String.slice(part, (start + length)..-1//1), false}
    ]
  end

  # Every word must match a token; the score is their mean. Highlights: token index =>
  # {start, length}.
  defp match_tokens(tokens, words) do
    matches = Enum.map(words, &best_token(tokens, &1))

    if Enum.any?(matches, &is_nil/1) do
      nil
    else
      score = (matches |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / length(matches)
      highlights = Map.new(matches, fn {_score, index, range} -> {index, range} end)
      {score, highlights}
    end
  end

  defp best_token(tokens, word) do
    tokens
    |> Enum.with_index()
    |> Enum.map(fn {token, index} ->
      case token_score(token, word) do
        nil -> nil
        {score, range} -> {score, index, range}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
  end

  defp token_score(token, word) do
    word_length = String.length(word)
    token_length = String.length(token)

    cond do
      token == word ->
        {1.0, {0, token_length}}

      String.starts_with?(token, word) ->
        {0.75 + 0.2 * word_length / token_length, {0, word_length}}

      word_length >= 3 and String.contains?(token, word) ->
        [before | _rest] = String.split(token, word, parts: 2)
        {0.6, {String.length(before), word_length}}

      # Codes ("EC153") are exact: a near one is another municipality.
      word_length >= 4 and not String.match?(word, ~r/\d/) ->
        typo_score(token, word, word_length, token_length)

      true ->
        nil
    end
  end

  # A misspelt word, whole or still being typed.
  defp typo_score(token, word, word_length, token_length) do
    similarity =
      max(
        String.jaro_distance(word, token),
        String.jaro_distance(word, String.slice(token, 0, word_length))
      )

    if similarity >= @typo_threshold,
      do: {0.55 * similarity, {0, min(word_length, token_length)}}
  end
end
