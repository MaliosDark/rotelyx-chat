#!/usr/bin/env python3
"""Which countries this can be listed in, and how many that is.

    python3 tool/market/availability.py

# Why this is a script and not a paragraph

The answer is a number, the number is arithmetic over a list, and a number
written by hand in a document is wrong the first time somebody edits the list
beside it. So the list is the source and the number is derived.

Researched August 2026. See docs/JURISDICTIONS.md for the reasoning behind each
exclusion. **Not legal advice.**

# The tiers

    blocked     Cannot be listed. Sanctions, or the store does not operate there
    licence     Requires a cryptography licence that this product cannot obtain
                without becoming a different product
    firewall    Can be listed and will not work: the state blocks it
    law         Can be listed today, under a law that could require changing it
    calls       Ships, but encrypted voice and video are the specific target
    open        No structural obstacle

`law` and `calls` count as available. `blocked`, `licence` and `firewall` do not.
"""

# Every country in the world, by region, with what stands in the way.
# Regions are for reading; the classification is what counts.
COUNTRIES = {
    "Europe": {
        "Albania": "open", "Andorra": "open", "Austria": "open",
        "Belarus": "blocked", "Belgium": "open", "Bosnia and Herzegovina": "open",
        "Bulgaria": "open", "Croatia": "open", "Cyprus": "open",
        "Czechia": "open", "Denmark": "open", "Estonia": "open",
        "Finland": "open", "France": "open", "Germany": "open",
        "Greece": "open", "Hungary": "open", "Iceland": "open",
        "Ireland": "open", "Italy": "open", "Kosovo": "open",
        "Latvia": "open", "Liechtenstein": "open", "Lithuania": "open",
        "Luxembourg": "open", "Malta": "open", "Moldova": "open",
        "Monaco": "open", "Montenegro": "open", "Netherlands": "open",
        "North Macedonia": "open", "Norway": "open", "Poland": "open",
        "Portugal": "open", "Romania": "open", "Russia": "blocked",
        "San Marino": "open", "Serbia": "open", "Slovakia": "open",
        "Slovenia": "open", "Spain": "open", "Sweden": "law",
        "Switzerland": "open", "Ukraine": "open", "United Kingdom": "law",
        "Vatican City": "open",
    },
    "Americas": {
        "Antigua and Barbuda": "open", "Argentina": "open", "Bahamas": "open",
        "Barbados": "open", "Belize": "open", "Bolivia": "open",
        "Brazil": "open", "Canada": "open", "Chile": "open",
        "Colombia": "open", "Costa Rica": "open", "Cuba": "blocked",
        "Dominica": "open", "Dominican Republic": "open", "Ecuador": "open",
        "El Salvador": "open", "Grenada": "open", "Guatemala": "open",
        "Guyana": "open", "Haiti": "open", "Honduras": "open",
        "Jamaica": "open", "Mexico": "open", "Nicaragua": "open",
        "Panama": "open", "Paraguay": "open", "Peru": "open",
        "Saint Kitts and Nevis": "open", "Saint Lucia": "open",
        "Saint Vincent and the Grenadines": "open", "Suriname": "open",
        "Trinidad and Tobago": "open", "United States": "open",
        "Uruguay": "open", "Venezuela": "open",
    },
    "Asia": {
        "Afghanistan": "blocked", "Armenia": "open", "Azerbaijan": "open",
        "Bahrain": "calls", "Bangladesh": "open", "Bhutan": "open",
        "Brunei": "open", "Cambodia": "open", "China": "firewall",
        "Georgia": "open", "India": "law", "Indonesia": "open",
        "Iran": "blocked", "Iraq": "open", "Israel": "open",
        "Japan": "open", "Jordan": "calls", "Kazakhstan": "licence",
        "Kuwait": "calls", "Kyrgyzstan": "open", "Laos": "open",
        "Lebanon": "open", "Malaysia": "open", "Maldives": "open",
        "Mongolia": "open", "Myanmar": "licence", "Nepal": "open",
        "North Korea": "blocked", "Oman": "calls", "Pakistan": "licence",
        "Palestine": "open", "Philippines": "open", "Qatar": "calls",
        "Saudi Arabia": "calls", "Singapore": "open", "South Korea": "open",
        "Sri Lanka": "open", "Syria": "law", "Taiwan": "open",
        "Tajikistan": "open", "Thailand": "open", "Timor-Leste": "open",
        "Turkey": "open", "Turkmenistan": "firewall", "United Arab Emirates": "calls",
        "Uzbekistan": "open", "Vietnam": "licence", "Yemen": "open",
    },
    "Africa": {
        "Algeria": "open", "Angola": "open", "Benin": "open",
        "Botswana": "open", "Burkina Faso": "open", "Burundi": "open",
        "Cabo Verde": "open", "Cameroon": "open",
        "Central African Republic": "open", "Chad": "open", "Comoros": "open",
        "Congo": "open", "DR Congo": "open", "Djibouti": "open",
        "Egypt": "calls", "Equatorial Guinea": "open", "Eritrea": "open",
        "Eswatini": "open", "Ethiopia": "open", "Gabon": "open",
        "Gambia": "open", "Ghana": "open", "Guinea": "open",
        "Guinea-Bissau": "open", "Ivory Coast": "open", "Kenya": "open",
        "Lesotho": "open", "Liberia": "open", "Libya": "open",
        "Madagascar": "open", "Malawi": "open", "Mali": "open",
        "Mauritania": "open", "Mauritius": "open", "Morocco": "open",
        "Mozambique": "open", "Namibia": "open", "Niger": "open",
        "Nigeria": "open", "Rwanda": "open", "Sao Tome and Principe": "open",
        "Senegal": "open", "Seychelles": "open", "Sierra Leone": "open",
        "Somalia": "open", "South Africa": "open", "South Sudan": "open",
        "Sudan": "blocked", "Tanzania": "open", "Togo": "open",
        "Tunisia": "open", "Uganda": "open", "Zambia": "open",
        "Zimbabwe": "open",
    },
    "Oceania": {
        "Australia": "law", "Fiji": "open", "Kiribati": "open",
        "Marshall Islands": "open", "Micronesia": "open", "Nauru": "open",
        "New Zealand": "open", "Palau": "open", "Papua New Guinea": "open",
        "Samoa": "open", "Solomon Islands": "open", "Tonga": "open",
        "Tuvalu": "open", "Vanuatu": "open",
    },
}

AVAILABLE = {"open", "law", "calls"}

REASON = {
    "blocked": "Cannot be listed: sanctions, or no store",
    "licence": "Cryptography licence required, and it cannot be met",
    "firewall": "Would be listed and blocked by the state",
    "law": "Available, under a law that could force a change",
    "calls": "Available, but encrypted calls are the target",
    "open": "No structural obstacle",
}


def main():
    tally = {tier: [] for tier in REASON}
    for countries in COUNTRIES.values():
        for name, tier in countries.items():
            tally[tier].append(name)

    total = sum(len(v) for v in tally.values())
    available = sum(len(tally[t]) for t in AVAILABLE)

    print(f"{total} countries examined\n")

    for region, countries in COUNTRIES.items():
        ok = sum(1 for t in countries.values() if t in AVAILABLE)
        print(f"  {region:<10} {ok:>3} of {len(countries):>3}")

    print()
    for tier in ("open", "calls", "law", "firewall", "licence", "blocked"):
        names = sorted(tally[tier])
        mark = "yes" if tier in AVAILABLE else "NO"
        print(f"  {tier:<9} {len(names):>3}  {mark:<4} {REASON[tier]}")
        if tier not in AVAILABLE or tier != "open":
            for name in names:
                print(f"              {name}")

    print()
    print(f"AVAILABLE IN {available} OF {total} COUNTRIES "
          f"({available * 100 // total} percent)")
    print(f"  of which {len(tally['open'])} with no caveat at all")
    print(f"  {len(tally['law']) + len(tally['calls'])} with something written down")
    print(f"  {total - available} closed")


if __name__ == "__main__":
    main()
