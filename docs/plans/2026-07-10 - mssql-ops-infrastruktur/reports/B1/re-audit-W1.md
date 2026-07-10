# Block B1 — Re-Audit of Repair Wave 1

**Mode:** re-audit · **Block:** B1 (chunks C1–C4) · **Timestamp:** 2026-07-10T00:57:22+02:00
**Repair commit:** `54f38fdddaa5981b0e5402125579036b7a03ccfa` — `[B1] repair wave 1`
**Findings verified:** 6 (from initial consolidation `validated-findings.md`)

## Verdict

**Converged.** All six findings the wave was meant to address are resolved, and the
wave introduced **no** new problems (no broken references, no behavior change beyond the
documented fixes, no convention violations). The diff is doc + proc-scaffolding only; no
runtime contract changed. Return `findings: []`.

## Per-finding verification

### convention-B1-1 — Naming SSoT (Important) → RESOLVED
`docs/SQL/NAMING-CONVENTIONS.md` §9 was rewritten: the false "follows sections 2–4" claim
is replaced by a dedicated "admin-DB style, **not** the JTL Hungarian convention" subsection
with an element table (PascalCase, no `t`/Hungarian/`sp` prefixes) and a constraint table
(`PK_ops_*` etc., schema-qualified). `UX_ResetRequest_Active` is now explicitly documented in
a `[!NOTE]` distinguishing `UX_` (standalone unique index) from `IX_`/`UQ_`. The doc now
matches the as-built `0002_ops_schema_tables.sql`. Shipped objects correctly left unrenamed.

### convention-B1-2 — `SET NOCOUNT ON` drift (Nice-to-have) → RESOLVED
All five PayPal procs (`spPaypalGetAccessToken`, `spPaypalCreateAccessToken`,
`spPaypalTrackingCallApi`, `spPaypalTrackingVersand`, `spPaypalTrackingLieferschein`) now open
their body with `SET NOCOUNT ON;` as the first statement inside `BEGIN` — grep confirms all five.
Consistent with the other 8 C1 procs and 11 C2 reset procs.

### convention-B1-3 — file-header style divergence (Nice-to-have) → RESOLVED
Handled via the sanctioned "record it in `db-migrations/README.md` §3" option: README §3 gains
a "File-header convention" block documenting the two layer-specific shapes (Ebene-A boxed banner,
Ebene-B compact line + `@see`). The divergence is now an intentional, documented convention
rather than undocumented drift — acceptable resolution per the finding's own fix text.

### logic-B1-1 — unreachable `RETURN -1` dead code (Nice-to-have) → RESOLVED
`spEnsureArticleCustomField`: the unreachable `RETURN -1` after the sev-16 `RAISERROR` is
removed and a comment explains control transfers to the outer CATCH/THROW; header updated from
"-1 when not found" to "raises on missing definition". The dependent dead guards are all gone:
`spSetArticleCustomFieldValue` (dropped `DECLARE @returnCode` + `IF @returnCode <> 0 RETURN -1`),
`spArticleAppendPriceHistory` and `spArticleAppendLabelHistory` (dropped `IF @returnCode <> 0 RETURN`).
Grep confirms **zero** remaining `returnCode` references across the four files; callers now `EXEC`
without capturing a return code. Headers updated to describe the throw contract. No behavior change
(the removed paths were unreachable).

### logic-B1-2 — label names not sanitised before `;`-delimited write (Nice-to-have) → RESOLVED
`spArticleAppendLabelHistory` write side now runs each label through
`Robotico.fnEscapedCSVSanitize(REPLACE(l.cName, ',', ''), NULL)` inside a derived table and orders
by the normalized `t.label` — stripping `;`, quotes and CR/LF that previously could corrupt the
`'; '` field / CRLF entry structure. The ORDER-BY divergence (`l.cName` vs `t.label`) is closed:
both write and read-back aggregate `STRING_AGG(t.label) WITHIN GROUP (ORDER BY t.label)` over the
normalized form. Checked for a whitespace-mismatch regression: `fnEscapedCSVSanitize` itself applies
`LTRIM(RTRIM(...))`, matching the read-back's `LTRIM(RTRIM(value))`, so equal label sets still
compare equal — no new spurious-change path introduced.

### T1 — coverage gap on two DB-mutation actions (Nice-to-have) → ACCEPTED / DROPPED
No test added, which is the finding's own sanctioned outcome ("No action required if the
accepted-scope decision stands"; §7 ports only pre-existing `*_Tests.sql`, and the source had none
for these two actions). Recorded as a conscious scope decision, not an open defect. Dropped from
the carry-forward set.

## New problems introduced by the wave

None. The changes are confined to (a) two documentation files (`NAMING-CONVENTIONS.md`,
`db-migrations/README.md`), (b) additive `SET NOCOUNT ON;` lines, and (c) removal of provably
unreachable code plus one write-side normalization. No object signatures, grants, or cross-chunk
contracts changed; no dangling identifiers remain.
