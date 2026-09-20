# Names and domains

Checked September 19, 2026 at 22:01 PDT, September 20 at 05:01 UTC. This is a naming shortlist and a public registration snapshot. No domains were purchased or reserved.

Keep Amanuensis as the internal project name while choosing a public name. A closely named product, [Amanu](https://getamanu.com/docs/), already offers local Mac dictation, cleanup, app rules, and a recording HUD. A shorter variation of Amanuensis would risk confusion with a direct competitor.

## Three recommendations

1. **Sayspan**, pronounced "say-span". My first choice for a compact utility. Seven letters, easy to spell aloud, and broad enough for dictation and meeting transcripts. Start with `sayspan.app`; consider `sayspan.com` as a redirect. Exact-name searches with software, app, and dictation found no identifiable product collision in this pass. That is a limited search result, not a clearance finding.
2. **Sayfern**, pronounced "say-fern". Better if the visual identity uses a soft green accent and a simple organic mark. `sayfern.app` and `sayfern.com` had no RDAP records. No software collision surfaced. A dental practice uses the name according to an [employee's public professional profile](https://ph.jobstreet.com/profiles/krizzamae-fernandez-MSSzrD62xY), so the name is not unused everywhere.
3. **Utterleaf**, pronounced "utter-leaf". A more distinctive alternative with an obvious speech reference. `utterleaf.app` and `utterleaf.com` had no RDAP records. It is longer and can sound like "utterly" when spoken quickly; test that before picking it. Exact-name searches found no identifiable software product in this pass.

Use `.app` for the consumer download site. A matching `.com` redirect would reduce mistyped addresses. `.dev` suits documentation but feels less natural as the main address for a general dictation app. These are design judgments, not search-ranking claims.

## Registry and DNS checks

Registry endpoints came from the [IANA RDAP bootstrap](https://data.iana.org/rdap/dns.json). Each domain below was queried directly using an unauthenticated HTTP GET. DNS checks queried NS records through [Google Public DNS](https://developers.google.com/speed/public-dns/docs/doh/json).

| Candidate | Registry RDAP response | DNS response |
| --- | --- | --- |
| sayspan.app | [404, no record](https://pubapi.registry.google/rdap/domain/sayspan.app) | NXDOMAIN |
| sayspan.com | [404, no record](https://rdap.verisign.com/com/v1/domain/sayspan.com) | NXDOMAIN |
| sayspan.dev | [404, no record](https://pubapi.registry.google/rdap/domain/sayspan.dev) | NXDOMAIN |
| sayfern.app | [404, no record](https://pubapi.registry.google/rdap/domain/sayfern.app) | NXDOMAIN |
| sayfern.com | [404, no record](https://rdap.verisign.com/com/v1/domain/sayfern.com) | NXDOMAIN |
| sayfern.dev | [404, no record](https://pubapi.registry.google/rdap/domain/sayfern.dev) | NXDOMAIN |
| utterleaf.app | [404, no record](https://pubapi.registry.google/rdap/domain/utterleaf.app) | NXDOMAIN |
| utterleaf.com | [404, no record](https://rdap.verisign.com/com/v1/domain/utterleaf.com) | NXDOMAIN |
| sayleaf.app | [200, registered](https://pubapi.registry.google/rdap/domain/sayleaf.app) | NS records present |
| sayleaf.com | [200, registered](https://rdap.verisign.com/com/v1/domain/sayleaf.com) | NS records present |

For reproducibility, DNS URLs follow `https://dns.google/resolve?name=sayspan.app&type=NS`, substituting each domain. NXDOMAIN was JSON status `3`; the registered Sayleaf domains returned status `0` with name servers. Two extra checks, `sayleaf.dev` and `inkwake.app`, also returned RDAP 404 and NXDOMAIN, but they are weaker choices than the shortlist.

A registry 404 means no matching registration record was returned at that moment. It does not guarantee registrar availability, normal pricing, or that a registry has not reserved the name. NXDOMAIN only describes DNS, and a registered domain can have no DNS records. Check registration and renewal pricing at checkout after choosing a name. No trademark clearance is claimed.

## Names screened out

| Name | Reason |
| --- | --- |
| Amanu | [Existing local Mac dictation app](https://getamanu.com/) |
| Verblet | [Existing Mac text cleanup utility](https://www.verblet.com/) |
| Sayform | [Existing speech-to-polished-text app](https://sayform.app/) |
| Sayloom | [Existing voice language-practice product](https://sayloom.com/en) |
| Hushline | [Existing speech-generation product](https://www.hushline.net/) and [privacy software](https://github.com/scidsg/hushline) |
| QuillBy | [Existing productivity app](https://play.google.com/store/apps/details?id=com.quillbyapp) |
| Inkward | [Existing writing and journaling product](https://inkward.life/) |
| Telltide | [Existing software feedback product](https://telltide.com/) |

These collisions are enough to prefer another name without drawing conclusions about trademark rights. The shortlist should also pass a practical spoken test: ask someone to type the name after hearing it once, then dictate it through the app's initial speech model.
