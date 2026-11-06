defmodule Iec.WardsTest do
  use ExUnit.Case, async: true

  alias Iec.Wards
  alias Iec.Wards.NameMatch

  defp ward(ward_id, municipality_id, municipality_name) do
    %{
      ward_id: ward_id,
      ward_number: rem(ward_id, 1000),
      municipality_id: municipality_id,
      municipality_name: municipality_name,
      province_id: 3,
      province_name: "Gauteng"
    }
  end

  defp index do
    Wards.build_index([
      ward(79_700_001, 7970, "TSH - City of Tshwane"),
      ward(79_700_045, 7970, "TSH - City of Tshwane"),
      ward(79_800_001, 7980, "JHB - City of Johannesburg"),
      ward(79_800_045, 7980, "JHB - City of Johannesburg"),
      ward(74_801_003, 7481, "GT481 - Mogale City"),
      ward(74_803_003, 7483, "GT483 - Westonaria"),
      ward(31_300_001, 3130, "MP313 - Steve Tshwete")
    ])
  end

  defp ward_ids(found), do: Enum.map(found.wards, & &1.ward_id)
  defp municipality_ids(found), do: Enum.map(found.municipalities, & &1.municipality_id)

  describe "search/3" do
    test "finds a ward by municipality and number, in any order and case" do
      assert ward_ids(Wards.search("Tshwane 45", index())) == [79_700_045]
      assert ward_ids(Wards.search("ward 45, tshwane", index())) == [79_700_045]
      assert ward_ids(Wards.search("ward45 Tshwane", index())) == [79_700_045]
      assert ward_ids(Wards.search("wyk 45 TSH", index())) == [79_700_045]
    end

    test "forgives misspelt and half-typed names" do
      assert [7970 | _] = municipality_ids(Wards.search("tswane", index()))
      assert [7980 | _] = municipality_ids(Wards.search("johanesburg", index()))
      assert [7970 | _] = municipality_ids(Wards.search("tshw", index()))
      assert ward_ids(Wards.search("johannesbrug 1", index())) == [79_800_001]
    end

    test "knows the big cities by their own names" do
      found = Wards.search("Pretoria 45", index())
      assert ward_ids(found) == [79_700_045]
      assert [%{municipality_id: 7970, place: "pretoria"}] = found.municipalities

      assert [%{municipality_id: 7980, place: "soweto"}] =
               Wards.search("soweto", index()).municipalities
    end

    test "matches municipality codes exactly, not as typos" do
      assert ward_ids(Wards.search("GT481 3", index())) == [74_801_003]
      assert municipality_ids(Wards.search("gt481", index())) == [7481]
    end

    test "finds a ward by its IEC ward id" do
      assert ward_ids(Wards.search("79800045", index())) == [79_800_045]
      assert ward_ids(Wards.search("12345678", index())) == []
    end

    test "a number alone finds that ward in every municipality, up to the limit" do
      found = Wards.search("45", index(), limit: 1)
      assert length(found.wards) == 1
      assert found.more == 1
      assert found.municipalities == []
      assert found.ward_number == 45
    end

    test "marks what matched in each name" do
      [match | _] = Wards.search("tshw", index()).municipalities

      assert match.segments == [
               {"TSH - City of ", false},
               {"Tshw", true},
               {"ane", false}
             ]
    end

    test "nothing for an empty or unknown query" do
      assert Wards.search("  ", index()).municipalities == []
      assert Wards.search("xyzzy", index()).municipalities == []
    end
  end

  describe "NameMatch.match/2" do
    test "ignores accents, case and punctuation" do
      assert NameMatch.match("EC101 - Dr. Beyers Naudé", NameMatch.words("naude"))
      assert NameMatch.match("NC084 - !KHEIS", NameMatch.words("kheis"))
    end

    test "every word must match" do
      refute NameMatch.match("TSH - City of Tshwane", NameMatch.words("tshwane durban"))
    end

    test "a whole word beats its start, which beats a typo" do
      whole = NameMatch.match("WC044 - George", ["george"]).score
      start = NameMatch.match("WC044 - George", ["geo"]).score
      typo = NameMatch.match("WC044 - George", ["goerge"]).score
      assert whole > start and start > typo
    end
  end
end
