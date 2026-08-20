# Where this can be shipped, and where it cannot

Researched August 2026. **Not legal advice**, and not a substitute for a lawyer
before the first release. What it is: the shape of the problem, the specific
rules that bite an application of this kind, and the questions worth paying
somebody to answer.

## Four questions people run together

They have different answers and different consequences, and treating them as one
is how a launch gets stopped by the wrong one.

| | |
|---|---|
| **Export** | May you lawfully publish it from where you are? |
| **Distribution** | Will Apple and Google carry it there? |
| **Use** | May a person there run it without breaking their own law? |
| **Compliance** | Would obeying local law require changing what this is? |

The last one is the dangerous one. A country can be perfectly open to your
launch and still have a law that only a product with a back door can satisfy.

---

# 1. Export, which is easier than it looks

The controlling question is whether the cryptography is **standard**.

The EAR defines "non-standard cryptography" as proprietary or unpublished
cryptographic functionality: algorithms or protocols that have not been adopted
by a recognised standards body **and** have not otherwise been published.

Rotelyx is on the right side of that line:

| | Where it is published |
|---|---|
| MLS | RFC 9420, IETF |
| X25519 | RFC 7748, IETF |
| ML-KEM-768 | FIPS 203, NIST |
| X-Wing | Published IETF draft and a public paper |
| ChaCha20-Poly1305 | RFC 8439, IETF |

Nothing here is invented, and that was already the right engineering decision.
It is also the difference between a form and a licence application.

**The fork that decides the paperwork is whether the protocol source is
published.**

**If it is public**, publicly available encryption source code is treated very
differently, and since a March 2021 rule change the email notification to BIS is
required only for **non-standard** cryptography. Standard cryptography published
as open source is close to the lightest case there is.

**If it is not public**, it is mass-market encryption software, self-classified
under License Exception ENC 740.17(b)(1), which is a report rather than an
application, plus an annual self-classification report to BIS due by 1 February
for the preceding year.

Either way there is no licence to be refused. Correct an earlier note in
`docs/RELEASING.md`: the CCATS route and the notification email are not both
automatically required, and which applies depends on the answer above.

## France, which catches everybody

Décret n°2007-663 classifies even ordinary TLS as a "moyen de cryptologie", so a
declaration to ANSSI is required. It is a declaration, not a licence, and since
2024 it can be filed through App Store Connect rather than sent to ANSSI
directly. Nobody is refused; people are simply surprised.

---

# 2. Where you cannot distribute at all

United States comprehensive sanctions. This is not about encryption; it is about
who may receive American software, and the App Store and Play are American.

| | |
|---|---|
| **North Korea** | Comprehensive embargo. No route |
| **Iran** | Embargoed, but General License D-2 authorises software incident to personal communications. A messenger is arguably squarely inside it, and this is the single most worthwhile question to put to a lawyer |
| **Cuba** | Comprehensive embargo |
| **Crimea, Donetsk, Luhansk** | Comprehensive embargo |
| **Syria** | **Changed.** Sanctions were lifted in July 2025 and the Commerce Department amended the EAR in September 2025. Newly open, and worth checking again at launch |
| **Russia, Belarus** | Not a full embargo, and encryption software exports were specifically tightened. Treat as closed without advice |

There is a second edge here worth knowing: sanctions also restrict distribution
**by** developers located in those countries, which is a question about where
Ideoa Labs is, not about where users are.

---

# 3. Where users are blocked, whatever you do

You may lawfully ship it and it will not work.

| | |
|---|---|
| **China** | Signal was blocked in 2026, following WhatsApp and Telegram. The Great Firewall plus commercial encryption rules make this closed in both directions |
| **Russia** | Blocks WhatsApp, Telegram, Signal, Discord and most VPN protocols through deep packet inspection. A new foreign-app crackdown in 2026 |
| **Iran** | Long-standing blocks on encrypted messengers |
| **North Korea, Turkmenistan** | No meaningful open internet |
| **UAE, Saudi Arabia, Qatar, Egypt** | Encrypted **voice and video** are the specific target. Text often works while calls do not, which matters directly to the call feature |

An honest note about this category: a blocked country is not a country with no
users. It is a country where your users need a VPN and where the mailbox host
matters more than anything in the client.

---

# 4. Where the law would force you to change what this is

The category that should decide the roadmap, because compliance here means
building the thing the product exists to refuse.

## United Kingdom

Section 121 of the Online Safety Act lets Ofcom require "accredited technology"
to scan for CSAM and terrorism content, **including inside end-to-end encrypted
messages**. Full operation was targeted for April 2026.

No technology exists that does this without breaking encryption. Signal and
WhatsApp signed an open letter against it; Apple said it would withdraw iMessage
and FaceTime from the UK rather than build it.

The power exists and has not been used against a major messenger yet. Shipping
in the UK means accepting that it might be.

## European Union

Better than it was, and not settled. The interim regulation expired on 4 April
2026 and was extended to 3 April 2028 while Chat Control 2.0 is negotiated. In
July 2026 Parliament passed amendments that **exclude end-to-end encrypted
services** from the scanning regime.

Parliament's position is not the final law. The Council has still to decide.
This is the one to watch monthly rather than annually.

## India

Rule 4(2) of the IT Rules 2021 requires messaging services to identify the
"first originator" of a message, which cannot be done on an end-to-end encrypted
service without changing it. WhatsApp's challenge is still before the Delhi High
Court.

**It binds "significant social media intermediaries", meaning over five million
registered users.** Below that threshold it does not apply, which makes India
launchable now and a decision later. Note this is exactly the kind of success
that creates a legal problem.

## Australia

The Telecommunications and Other Legislation Amendment (Assistance and Access)
Act lets agencies compel technical assistance. It says it cannot require a
"systemic weakness", and what that phrase excludes has never been tested.

## Sweden

A proposal to require back doors in Signal and similar applications, aimed at
March 2026. Signal said publicly it would leave rather than comply.

---

# 5. Where a licence is required that you will not get

Import or use of cryptography needs government permission, and permission
generally means key escrow or a domestic entity.

| | |
|---|---|
| **Russia** | FSB and Ministry of Economic Development licences, applied for by an entity registered in Russia |
| **China** | Permit from the State Encryption Administration |
| **Kazakhstan** | Licence from the National Security Committee |
| **Belarus, Vietnam, Pakistan, Myanmar, Iran, Saudi Arabia, Morocco, Tunisia** | Various licensing, registration or import controls |

For a product whose argument is that no third party holds anything, these are
not obstacles to work through. They are requests to become a different product.

---

# 6. What this means for a launch

**Ship first:** United States, Canada, EU, Switzerland, Norway, Japan, South
Korea, Taiwan, Australia, New Zealand, most of Latin America, most of Africa,
Israel, Singapore. No structural obstacle beyond the filings in section 1.

**Ship with the risk written down:** the United Kingdom, because of section 121.
India, while below five million users.

**Do not list:** North Korea, Cuba, Crimea, Donetsk, Luhansk, Iran without
advice on General License D-2, Russia, Belarus, China.

**Check again at launch:** Syria, newly open. The EU, because the Council has
not decided.

## The three filings to actually do

1. Answer the export question by settling whether the protocol source is
   published, then either file nothing much or file the annual
   self-classification report. `ITSAppUsesNonExemptEncryption` is already
   correctly set to true in `ios/Runner/Info.plist`.
2. The French declaration, through App Store Connect.
3. Both stores' country availability lists, set deliberately rather than left
   at "all countries", which is the default and is wrong.

## The one strategic observation

Every regime in section 4 is aimed at services that **can** comply: a company
with accounts, a directory, and a server that knows who its users are.

Rotelyx has none of those. There is no account to identify, no directory to
query, and no server holding anything readable. A traceability order asks for
something that does not exist rather than something being withheld.

That is a stronger position than Signal's, which still requires a phone number.
It is not a legal defence and no court has tested it. But it is worth stating
plainly to a regulator, and it is worth not quietly building the account system
that would take it away.

---

Sources consulted August 2026: BIS and eCFR on 740.17 and non-standard
cryptography; ANSSI on French declaration requirements; OFAC and EFF on Syria
and Iran general licences; Ofcom and Proton on section 121; European Parliament
coverage of the July 2026 Chat Control votes; Internet Society and EFF on India's
traceability rule.
