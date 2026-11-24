# Release check and download at scale

Research note, 2026-11-24, for [#2215](https://github.com/DivyanshGolyan/rui/issues/2215) (part of #2212).
Question: does Rui's release check and upgrade download hold up for 1,000 to 100,000 users, and what would serving the version answer or the files from Cloudflare take?

Each claim is marked **documented** (a first-party GitHub or Cloudflare page says it), **observed** (I ran it from this research machine on 2026-11-24, one network, one IP), **source** (read in Rui at `60d63ca`), or **inferred**.

## Answer

- The version check is the weak part, not the download. Every check makes three unauthenticated requests to `github.com` web routes, one of which renders a full 153 KB HTML release page. GitHub documents no limit for these web routes, but it does throttle them per IP (observed: HTTP 429 with `Retry-After: 120` after about 40 quick requests). Users behind one office NAT or one CGNAT address share that budget.
- When GitHub throttles, Rui fails quietly: the update badge does not appear and an explicit upgrade fails with a download error. Nothing else breaks (source).
- Release asset bytes are the strong part. GitHub documents no bandwidth limit for releases and a 2 GiB per-file limit; Rui's archives are about 7 to 8 MB. The asset hosts served 40 of 40 quick downloads in the probe. The only documented catch is the acceptable-use clause that lets GitHub throttle "significantly excessive" bandwidth.
- Cloudflare's redirect rules are not a bottleneck. A Free zone gets 10 Single Redirect rules, and Cloudflare documents no per-request quota for them.
- Cheapest fix for the check: keep the answer on Cloudflare. On each release, the release workflow rewrites a static `ruicode.com/releases/latest` redirect to point at the exact tag. Rui then reads that `Location` header without following it, so a check never reaches `github.com`. This is free and needs a small client change plus one Cloudflare API token in CI.
- Fix for the files, if GitHub ever throttles them: upload each release to an R2 bucket served on `ruicode.com`. R2 has no egress charge, and its free tier covers 10 GB of storage and 10 million reads per month. Workers static assets would also work, since files up to 25 MiB are free with no request limit. Either moves trust in `SHA256SUMS` from GitHub to the Cloudflare account.

## What Rui does today (source)

- `src/release_candidate.zig` `discover` runs curl on `https://ruicode.com/releases/latest` with `--location --max-redirs 5 --output /dev/null --write-out %{url_effective}` (`src/download_policy.zig` `arguments`). curl follows every hop and GETs the final page body, then discards it.
- The redirect chain (observed):
  1. `ruicode.com/releases/latest` returns 302 from Cloudflare to `github.com/DivyanshGolyan/rui/releases/latest`.
  2. GitHub returns 302 (`Cache-Control: no-cache`) to `/releases/tag/v0.93.0`.
  3. GitHub returns 200 with 153,107 bytes of HTML (`Cache-Control: max-age=0, private, must-revalidate`). This is a full page render per check.
- Rui then fetches `ruicode.com/releases/download/<tag>/SHA256SUMS`. Cloudflare redirects (302) to `github.com/.../releases/download/...`, GitHub redirects (302) to a signed `release-assets.githubusercontent.com` URL, and that host serves the file (`Server: Windows-Azure-Blob`, `Via: varnish`, `X-Cache: HIT`). The archive goes through the same chain, capped at 256 MiB by `--max-filesize`.
- So each check costs 3 `github.com` web requests (2 redirects, 1 HTML page) and 1 asset-CDN request. An upgrade adds 1 more `github.com` redirect and an archive of about 7.3 MB (linux-x86_64) or 7.9 MB (darwin-arm64), per the release API asset sizes for v0.93.0.
- Cadence: `Overview.appDiscoverUpgrade` runs discovery once per Overview process (`discovery_attempted`). It is not a timer; it runs once per launch of the full-screen overview. "Hourly" in the issue is an assumption about how often users open it.
- Failure: `job.discover(...) catch {}` and `availability()` return null on failure, so a 429 means "no update shown". `--fail` makes curl exit non-zero on HTTP 4xx, and there is no retry on HTTP errors (only an IPv4 retry on resolve or connect failure, `download_policy.after`).

Rough load at 100,000 users each checking once an hour (inferred arithmetic): about 28 checks per second, 83 `github.com` requests per second, and 15 GB per hour of uncacheable HTML. A release that all of them install moves about 0.75 TB of archives.

## GitHub limits

### Documented

| Fact | Source |
| --- | --- |
| "Up to 1000 release assets may be associated with a single release. Each file included in a release must be under 2 GiB. There is no limit on the total size of a release, nor bandwidth usage." | [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) |
| "If we determine your bandwidth usage to be significantly excessive in relation to other users of similar features, we reserve the right to suspend your Account, throttle your file hosting, or otherwise limit your activity until you can reduce your bandwidth consumption." | [Acceptable Use Policies §9, Excessive Bandwidth Use](https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies) |
| REST API: unauthenticated limit is 60 requests per hour, "associated with the originating IP address". Secondary limits cover concurrency, per-endpoint per-minute rates and compute cost, with no numbers given for most. These docs cover only the REST API, GraphQL and LFS. They say nothing about web pages or release downloads. Rui avoids this API on purpose (`docs/contracts/store.md`). | [Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) |
| On 2025-05-08 GitHub tightened unauthenticated limits for HTTPS clones, anonymous REST calls and `raw.githubusercontent.com`, citing scraping, and advised authenticating. No numbers are given, and neither web pages nor release downloads are named. | [Changelog: Updated rate limits for unauthenticated requests](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/) |

**Not documented anywhere I found:** any per-IP limit, window or reset for unauthenticated `github.com` web pages (`/releases/latest`, `/releases/tag/...`, `/releases/download/...`) or for `release-assets.githubusercontent.com`. Also undocumented: how shared IPs are treated, and whether GitHub ever relaxes limits for known NAT or CGNAT ranges.

### GitHub statements and user reports (community, not docs)

- [Community discussion #159123](https://github.com/orgs/community/discussions/159123) (May 2025): logged-out users got 429s on `github.com` `/blob/` pages, on repository search, and on `raw.githubusercontent.com`. Install scripts that download binaries were also hit. A GitHub maintainer (martinwoodward, 2025-05-14) called it "an unintended consequence of throttling limits we've had to put in", said legitimate browsing was not meant to be limited, and said the logic had been adjusted. He gave no numbers.
- In the same thread, users reported throttling that matches **shared IPs**: a whole household blocked for about an hour after a few install scripts, a block lasting over 24 hours that the user blamed on CGNAT or IP reputation, and blocks that cleared after reconnecting to get a new IP. These are user claims, not confirmed by GitHub.
- No release-specific statement from GitHub turned up.

### Observed (2026-11-24, this research machine)

This machine sits on a cloud egress IP behind a proxy, which may be shared with other clients and may have worse reputation than a home or office address. One run, sequential requests with no delay, wall time not recorded:

| Request | Result |
| --- | --- |
| 100 × `github.com/DivyanshGolyan/rui/releases/latest` | 40 × 302, then 60 × 429 |
| then 40 × `.../releases/tag/v0.93.0` (153 KB HTML) | 40 × 200 |
| then 40 × `ruicode.com/releases/download/v0.93.0/SHA256SUMS`, following redirects | 40 × 200 |
| right after: `.../releases/latest`, `.../releases/tag/v0.93.0`, `github.com/cli/cli/releases/latest`, `ruicode.com/releases/latest` (followed) | 429 (`Retry-After: 120`, `Server: github.com`), 429, 403, 429 |

So GitHub throttles the unauthenticated `/releases/latest` route after a few dozen requests in a short burst from one IP. The block then spread to other `github.com` pages from that IP, including other repositories, and the 429 carried a 2-minute `Retry-After`. Why the tag page and the download redirect kept succeeding for a while is unknown. I did not run further pacing or recovery probes, so the sustained per-hour rate that stays under the limit is **unknown**.

Inferred for Rui: about 40 checks from one office NAT within a few minutes (for example, everyone opening Rui after a morning login) would hit the same limit. CGNAT users share an IP with strangers who also use GitHub, so a Rui user there can be throttled by traffic that has nothing to do with Rui. Throttling then also breaks those users' ordinary `github.com` browsing for a couple of minutes.

## Cloudflare limits for the current redirect rules (documented)

- Single Redirects: available on all plans. A Free zone gets 10 rules with wildcard support and no regex. "Single Redirects features and quotas are per zone and depend on the zone plan." Bulk Redirects on Free: 15 rules, 5 lists, 10,000 URLs. ([URL forwarding](https://developers.cloudflare.com/rules/url-forwarding/))
- I found no per-request quota or charge for redirect rules on any plan (inferred from its absence on the page above). Redirects are answered at the edge before any origin, so 28 requests per second is negligible for Cloudflare (inferred).

## Serving the answer and files from Cloudflare

### Version answer (recommended first step)

1. **Static redirect per release.** The release workflow rewrites the `ruicode.com/releases/latest` Single Redirect target to `https://github.com/DivyanshGolyan/rui/releases/tag/vX.Y.Z` through the Rulesets API, using a token scoped to the zone's redirect rules. Free plan, no new service. On its own, this removes one of the two `github.com` hits.
2. **Stop following the last hop.** Rui reads curl's `%{redirect_url}` with `--max-redirs 0` instead of following to the tag page. `fromEffectiveUrl` already validates exactly that URL shape, so the validation code needs no change. Rui then derives the asset URLs as today. A check costs zero `github.com` requests.
   - Cost: a stale rule during a failed release step could advertise an older tag. That is harmless, since it pins an existing tag. Rui's contract text in `docs/contracts/store.md` ("follows the HTTPS redirect chain") would need an update.
3. Alternative to 1: a Worker or a static asset that returns the tag (or a 302) from a file updated per release. Workers Free allows 100,000 Worker requests per day, and past that it returns Error 1027 or bypasses the Worker depending on fail mode ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/)). That cap is below the 100,000-users-hourly case. Workers Paid costs $5 per month with 10 million requests included, then $0.30 per million ([Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)). "Requests to static assets are free and unlimited" ([static assets billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)), so a static file avoids the cap. A redirect rule is simpler than either.

### Files (only if GitHub asset delivery becomes a problem)

- **R2 behind a `ruicode.com` custom domain.** Pricing is documented ([R2 pricing](https://developers.cloudflare.com/r2/pricing/)): "no charges for egress bandwidth". The free tier covers 10 GB-month storage, 1 million Class A (writes) and 10 million Class B (reads) per month. After that, Standard storage is $0.015 per GB-month and Class B $0.36 per million. Production use needs a custom domain, because `r2.dev` "is rate-limited and should only be used for development purposes". A custom domain also enables Cloudflare Cache, and only some file types are cached by default unless a Cache Everything rule is set ([public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/)).
  - Sizing (inferred): one release's platform archives, debug archives and SHA256SUMS come to about 90 MB. 10 GB holds about 100 releases, or the release workflow can prune old ones. 100,000 upgrades is 200,000 reads, well inside 10 million.
  - Whether a cache hit counts as a Class B read is **unknown** (not stated on the pricing page). Fewer billable reads than requests is likely but unconfirmed.
- **Workers static assets.** Free and unlimited requests, with a 25 MiB per-file limit and 20,000 files per Worker version on Free ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/)). Rui's archives (at most about 16 MB for debug builds) fit. Each release needs a full deploy of the asset set.
- **Large-file terms.** Cloudflare's CDN terms say non-Enterprise customers "must use" specific Paid Services ("e.g., the Developer Platform, Images, and Stream") "to serve video and other large files via the CDN". Cloudflare may limit a zone that serves "a disproportionate percentage of pictures, audio files, or other large files" without them ([Service-Specific Terms, CDN](https://www.cloudflare.com/service-specific-terms-application-services/)). Proxying or caching GitHub-hosted archives through a Free zone's plain CDN is therefore exactly the use this clause targets. Serving them from R2 or Workers (Developer Platform products) is the sanctioned route (inferred: the terms do not name R2 explicitly).
- **Trust.** Today `SHA256SUMS` and the archive both come from GitHub release assets, which only the release workflow can write. Moving both to Cloudflare means a Cloudflare account or token compromise can replace both together. Keeping `SHA256SUMS` on GitHub and only the archive on R2 keeps GitHub as the integrity anchor (inferred design note; no decision taken here).

## Unknowns

- GitHub's actual per-IP thresholds, windows and penalty growth for unauthenticated web routes and release asset hosts, and whether they differ for residential, office and cloud IPs.
- Whether the observed 429 threshold applies the same way to a residential or office IP. The probe ran from a cloud egress IP.
- Whether R2 cache hits on a custom domain are billed as Class B operations.
- Whether GitHub has ever enforced the §9 bandwidth clause against a project serving a few hundred GB of release assets per release. I found no first-party statement either way.
