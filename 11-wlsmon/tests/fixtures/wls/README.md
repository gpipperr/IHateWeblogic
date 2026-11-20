# WebLogic REST fixtures

- `search_real_14.1.2.json` - the **real** answer of the test host (FMW
  14.1.2, SPB 261112) to the search POST of `wlsmon.py` (`SEARCH`), captured
  2026-11-20 with one read-only call (development plan step 6b). Contains only
  server names, states and counters - no host names, no credentials.
- `search_ok.json` - the same structure with values for the tests (heap 84 %
  and 2 hogging threads on WLS_FORMS); the structure was verified against the
  real answer above.
- `servers.json` - `GET .../domainConfig/servers?fields=name&links=none`.

Findings of the verification: the field names of the prototype plan are
right on 14.1.2; `healthState` is an object (`state`, `subsystemName`,
`symptoms`); collections come as `{"items": [...]}`. The **first** search after
a start of the AdminServer took 11.3 s (REST application initialised lazily),
the following ones 0.17 - 0.22 s - the 20 s timeout of `wlsmon.py` covers it.
