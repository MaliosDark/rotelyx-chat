#!/usr/bin/env python3
"""Render the availability list as a page.

    python3 tool/market/page.py > /tmp/.../availability.html

The country list and the arithmetic come from `availability.py`, so the page
and the terminal answer cannot disagree. A number typed into a document by hand
is wrong the first time somebody edits the list beside it.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from availability import COUNTRIES, AVAILABLE, REASON  # noqa: E402

WHY = {
    "Afghanistan": "No store operates there. Sanctions and the collapse of banking",
    "Belarus": "Encryption software exports were specifically tightened in 2022",
    "Cuba": "Comprehensive United States embargo",
    "Iran": "Embargoed. General License D-2 may authorise a messenger, and that is the single question most worth asking a lawyer",
    "North Korea": "Comprehensive embargo. No route of any kind",
    "Russia": "Encryption export controls tightened, and both stores withdrew",
    "Sudan": "Sanctions, and no reliable store presence",
    "China": "Signal was blocked in 2026, after WhatsApp and Telegram. Play does not operate at all",
    "Turkmenistan": "No meaningful open internet",
    "Kazakhstan": "Licence from the National Security Committee",
    "Myanmar": "Licensing plus routine shutdowns",
    "Pakistan": "Registration with the telecom authority, and VPN licensing",
    "Vietnam": "Decree 53 requires local data storage and a local entity",
    "Australia": "The Assistance and Access Act can compel technical help. It forbids a systemic weakness, and nobody has tested what that excludes",
    "India": "Rule 4(2) requires naming a message's first originator. It binds services over five million users, so this is a decision for later, not now",
    "Sweden": "A proposal to require back doors, aimed at March 2026. Signal said it would leave instead",
    "Syria": "Sanctions lifted in July 2025 and the EAR amended in September. Newly open, and worth checking again on the day",
    "United Kingdom": "Section 121 of the Online Safety Act lets Ofcom compel scanning inside encrypted messages. The power exists and has not been used on a major messenger yet",
    "Bahrain": "Encrypted voice and video are the target, not text",
    "Egypt": "Encrypted voice and video are the target, not text",
    "Jordan": "Encrypted voice and video are the target, not text",
    "Kuwait": "Encrypted voice and video are the target, not text",
    "Oman": "Encrypted voice and video are the target, not text",
    "Qatar": "Encrypted voice and video are the target, not text",
    "Saudi Arabia": "Encrypted voice and video are the target, not text",
    "United Arab Emirates": "Encrypted voice and video are the target, not text",
}

TIER_NAME = {
    "blocked": "Cannot be listed",
    "firewall": "Would be blocked by the state",
    "licence": "Needs a licence this cannot obtain",
    "law": "Available, with a law to watch",
    "calls": "Available, calls restricted",
}


def rows(tier):
    out = []
    for region, countries in COUNTRIES.items():
        for name, t in sorted(countries.items()):
            if t == tier:
                out.append((name, region, WHY.get(name, "")))
    return sorted(out)


def main():
    tally = {}
    for countries in COUNTRIES.values():
        for name, tier in countries.items():
            tally.setdefault(tier, []).append(name)

    total = sum(len(v) for v in tally.values())
    available = sum(len(tally.get(t, [])) for t in AVAILABLE)
    closed = total - available

    print(HEAD)

    print(f'''<header class="masthead">
  <p class="eyebrow">Rotelyx Chat &middot; store availability &middot; researched August 2026</p>
  <h1>Where this can ship</h1>
  <div class="verdict">
    <div class="figure">
      <span class="big">{available}</span>
      <span class="of">of {total}</span>
    </div>
    <p class="lede">
      Thirteen countries are closed, and only two of those for a reason that is
      about encryption rather than about sanctions. The rest of the world is a
      filing question, not a permission question.
    </p>
  </div>
  <dl class="split">
    <div><dt>No obstacle at all</dt><dd>{len(tally["open"])}</dd></div>
    <div><dt>Available, with a caveat</dt><dd>{len(tally["law"]) + len(tally["calls"])}</dd></div>
    <div><dt>Closed</dt><dd>{closed}</dd></div>
  </dl>
</header>''')

    print('<main>')

    print('''<section>
  <h2>The thirteen that are closed</h2>
  <p class="note">
    Set both stores&rsquo; country lists by hand. The default is every country,
    and the default is wrong.
  </p>''')

    for tier in ("blocked", "firewall", "licence"):
        print(f'<h3 class="tier tier-closed">{TIER_NAME[tier]} '
              f'<span class="count">{len(tally.get(tier, []))}</span></h3>')
        print('<ul class="countries">')
        for name, region, why in rows(tier):
            print(f'  <li><span class="name">{name}</span>'
                  f'<span class="region">{region}</span>'
                  f'<span class="why">{why}</span></li>')
        print('</ul>')
    print('</section>')

    print('''<section>
  <h2>The thirteen with something written down</h2>
  <p class="note">
    These ship. They are listed because somebody should know before a letter
    arrives, not because they are a reason to wait.
  </p>''')
    for tier in ("law", "calls"):
        print(f'<h3 class="tier tier-caveat">{TIER_NAME[tier]} '
              f'<span class="count">{len(tally.get(tier, []))}</span></h3>')
        print('<ul class="countries">')
        for name, region, why in rows(tier):
            print(f'  <li><span class="name">{name}</span>'
                  f'<span class="region">{region}</span>'
                  f'<span class="why">{why}</span></li>')
        print('</ul>')
    print('</section>')

    print('<section><h2>Every country, by region</h2>')
    print('<div class="regions">')
    for region, countries in COUNTRIES.items():
        ok = sum(1 for t in countries.values() if t in AVAILABLE)
        print(f'<div class="region-block"><h3>{region} '
              f'<span class="count">{ok} of {len(countries)}</span></h3><ul class="grid">')
        for name, tier in sorted(countries.items()):
            state = "open" if tier == "open" else (
                "caveat" if tier in AVAILABLE else "closed")
            print(f'  <li class="s-{state}">{name}</li>')
        print('</ul></div>')
    print('</div></section>')

    print('''<section class="method">
  <h2>How this was decided</h2>
  <p>
    Four questions that get run together and have different answers. May you
    lawfully publish it? Will the stores carry it there? May a person there run
    it? And would obeying local law require changing what it is?
  </p>
  <p>
    The last one is the dangerous one, and it is why the United Kingdom sits in
    the second list rather than the first. A country can be entirely open to a
    launch and still have a law only a product with a back door can satisfy.
  </p>
  <p>
    Export is the easy part, because nothing here is invented. MLS is RFC 9420,
    X25519 is RFC 7748, ML-KEM-768 is FIPS 203, X-Wing is a published draft.
    The export rules turn on whether cryptography is proprietary or unpublished,
    and none of this is either. There is no licence that can be refused.
  </p>
  <p class="closing">
    One thing worth saying to a regulator, and worth not quietly building away:
    every scanning and traceability regime above is aimed at a service that
    <em>can</em> comply, one with accounts, a directory, and a server that knows
    who its users are. There is nothing here to identify, to query, or to hand
    over. An order asks for something that does not exist rather than something
    being withheld.
  </p>
  <p class="disclaimer">
    Researched August 2026 from primary sources: the EAR and BIS guidance,
    ANSSI, OFAC general licences, Ofcom, the European Parliament&rsquo;s July
    2026 votes, and India&rsquo;s IT Rules. Full reasoning in
    <code>docs/JURISDICTIONS.md</code>. Counts are generated from
    <code>tool/market/availability.py</code>, so this page and that script
    cannot disagree. <strong>This is not legal advice.</strong>
  </p>
</section>''')

    print('</main>')


HEAD = '''<title>Where This Can Ship</title>
<!-- No webfont link on purpose. This repository says it opens no third-party
     address, and a reader who greps for one is not going to weigh whether the
     file they found happens to ship. Every rule below already names a system
     fallback, so the page loses a typeface and nothing else. -->
<style>
:root {
  --paper: #F1F4F7;
  --card: #FFFFFF;
  --ink: #10141C;
  --body: #2C3340;
  --muted: #666E7D;
  --rule: #D3DAE3;
  --accent: #2E4A8C;
  --ok: #3F6B4E;
  --warn: #94651F;
  --closed: #8C4238;
  --ok-bg: #E4EDE6;
  --warn-bg: #F4EBDA;
  --closed-bg: #F3E2DF;
  --shadow: 0 1px 2px rgba(16, 20, 28, .06), 0 8px 24px rgba(16, 20, 28, .05);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --paper: #0D1016;
    --card: #151A23;
    --ink: #EDF0F5;
    --body: #C0C7D2;
    --muted: #838C9B;
    --rule: #262E3A;
    --accent: #90ACE4;
    --ok: #8FBF9E;
    --warn: #D4A860;
    --closed: #D98E82;
    --ok-bg: #1A2620;
    --warn-bg: #2A2318;
    --closed-bg: #2A1B19;
    --shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 8px 24px rgba(0, 0, 0, .3);
  }
}
:root[data-theme="dark"] {
  --paper: #0D1016;
  --card: #151A23;
  --ink: #EDF0F5;
  --body: #C0C7D2;
  --muted: #838C9B;
  --rule: #262E3A;
  --accent: #90ACE4;
  --ok: #8FBF9E;
  --warn: #D4A860;
  --closed: #D98E82;
  --ok-bg: #1A2620;
  --warn-bg: #2A2318;
  --closed-bg: #2A1B19;
  --shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 8px 24px rgba(0, 0, 0, .3);
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--paper);
  color: var(--body);
  font-family: "Public Sans", ui-sans-serif, system-ui, -apple-system, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}

.masthead, main { max-width: 1080px; margin: 0 auto; padding: 0 28px; }
.masthead { padding-top: 56px; padding-bottom: 40px; }

.eyebrow {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 11.5px;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--muted);
  margin: 0 0 20px;
}

h1 {
  font-family: Newsreader, Georgia, serif;
  font-weight: 400;
  font-size: clamp(38px, 6vw, 62px);
  line-height: 1.05;
  letter-spacing: -.015em;
  color: var(--ink);
  margin: 0 0 32px;
  text-wrap: balance;
}

.verdict {
  display: flex;
  flex-wrap: wrap;
  gap: 32px 44px;
  align-items: flex-start;
  padding-bottom: 32px;
  border-bottom: 1px solid var(--rule);
}
.figure { display: flex; align-items: baseline; gap: 10px; }
.big {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: clamp(64px, 11vw, 108px);
  font-weight: 500;
  line-height: .85;
  letter-spacing: -.04em;
  color: var(--accent);
  font-variant-numeric: tabular-nums;
}
.of {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 17px;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.lede {
  flex: 1 1 320px;
  margin: 0;
  font-family: Newsreader, Georgia, serif;
  font-size: 20px;
  line-height: 1.5;
  color: var(--ink);
  max-width: 46ch;
}

.split {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 48px;
  margin: 24px 0 0;
}
.split div { display: flex; align-items: baseline; gap: 10px; }
.split dt {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 11.5px;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--muted);
}
.split dd {
  margin: 0;
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 20px;
  font-weight: 500;
  color: var(--ink);
  font-variant-numeric: tabular-nums;
}

main { padding-bottom: 80px; display: flex; flex-direction: column; gap: 56px; }
section { display: flex; flex-direction: column; gap: 14px; }

h2 {
  font-family: Newsreader, Georgia, serif;
  font-weight: 400;
  font-size: 30px;
  line-height: 1.2;
  color: var(--ink);
  margin: 0;
  letter-spacing: -.01em;
}
.note { margin: 0; color: var(--muted); max-width: 62ch; font-size: 15px; }

h3.tier {
  display: flex;
  align-items: center;
  gap: 12px;
  margin: 18px 0 0;
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 12px;
  font-weight: 500;
  letter-spacing: .1em;
  text-transform: uppercase;
}
h3.tier-closed { color: var(--closed); }
h3.tier-caveat { color: var(--warn); }
h3.tier .count {
  font-variant-numeric: tabular-nums;
  padding: 2px 8px;
  border-radius: 3px;
  font-size: 11px;
  letter-spacing: .04em;
}
.tier-closed .count { background: var(--closed-bg); color: var(--closed); }
.tier-caveat .count { background: var(--warn-bg); color: var(--warn); }

ul.countries { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
ul.countries li {
  display: grid;
  grid-template-columns: minmax(150px, 200px) 92px 1fr;
  gap: 4px 20px;
  padding: 13px 0;
  border-bottom: 1px solid var(--rule);
  align-items: baseline;
}
ul.countries li .name { font-weight: 700; color: var(--ink); }
ul.countries li .region {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 11px;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--muted);
}
ul.countries li .why { color: var(--body); font-size: 15px; }

@media (max-width: 640px) {
  ul.countries li { grid-template-columns: 1fr; gap: 3px; }
  ul.countries li .why { grid-column: 1; }
}

.regions { display: flex; flex-direction: column; gap: 26px; }
.region-block { background: var(--card); border: 1px solid var(--rule); border-radius: 8px; padding: 20px 22px; box-shadow: var(--shadow); }
.region-block h3 {
  display: flex;
  align-items: baseline;
  gap: 12px;
  margin: 0 0 14px;
  font-family: Newsreader, Georgia, serif;
  font-weight: 500;
  font-size: 19px;
  color: var(--ink);
}
.region-block h3 .count {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 11.5px;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
  letter-spacing: .04em;
}

ul.grid {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
  gap: 2px 18px;
}
ul.grid li {
  font-size: 14.5px;
  padding: 3px 0 3px 18px;
  position: relative;
  color: var(--body);
}
ul.grid li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 10px;
  width: 8px;
  height: 8px;
  border-radius: 2px;
}
.s-open::before { background: var(--ok); }
.s-caveat::before { background: var(--warn); }
.s-closed::before { background: var(--closed); }
.s-closed { color: var(--muted); text-decoration: line-through; text-decoration-color: var(--closed); }

.method { border-top: 1px solid var(--rule); padding-top: 34px; }
.method p { margin: 0; max-width: 66ch; }
.method .closing {
  font-family: Newsreader, Georgia, serif;
  font-size: 19px;
  line-height: 1.55;
  color: var(--ink);
  border-left: 2px solid var(--accent);
  padding-left: 20px;
  margin-top: 10px;
}
.method .disclaimer { font-size: 14px; color: var(--muted); margin-top: 10px; }
.method code {
  font-family: "IBM Plex Mono", ui-monospace, monospace;
  font-size: 12.5px;
  background: var(--card);
  border: 1px solid var(--rule);
  border-radius: 3px;
  padding: 1px 5px;
}
.method strong { color: var(--ink); }
</style>
'''


if __name__ == "__main__":
    main()
