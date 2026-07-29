# `WorkflowProcedures/` — DEPRECATED as a deployment source

> [!WARNING]
> **These scripts are no longer the deployment source of truth.** The `Robotico.*`
> and our `CustomWorkflows.*` objects are now deployed via the versioned grate chain
> in [`db-migrations/`](../db-migrations/) (Ebene A). See decision **D12** in
> `docs/plans/2026-07-10 - mssql-ops-infrastruktur/`.

The files here are kept as **reference / provenance** for the ported migrations. Each
migration file under `db-migrations/eazybusiness/` names the `WorkflowProcedures/*`
source it was ported from (`-- Ported from …`). Do not deploy from this folder anymore.

## Where each object now lives

| Source here | Now deployed as |
|---|---|
| `api/CustomFieldAPI.sql` | `db-migrations/eazybusiness/functions/Robotico.fnGetArticleCustomFieldValue.sql` + `sprocs/Robotico.spEnsureArticleCustomField.sql` + `sprocs/Robotico.spSetArticleCustomFieldValue.sql` |
| `api/StringAndCSVUtilities.sql` | `db-migrations/eazybusiness/functions/Robotico.fnString*.sql` + `Robotico.fnEscapedCSV*.sql` (9 functions) |
| `Duplikaterkennung_Bestellungen.sql` | `functions/Robotico.fnFindDuplicateOrders.sql` + `functions/Robotico.fnHasOlderDuplicateOrder.sql` + `sprocs/Robotico.spCheckDuplicateOrder.sql` |
| `PayPal/Add Procudures and Tables.sql` | `up/0002_robotico_paypal_tables.sql` (tables + settings seed) + `sprocs/Robotico.spPaypal{GetAccessToken,CreateAccessToken,TrackingCallApi}.sql` |
| `PayPal/Workflowaktion.sql` | `sprocs/CustomWorkflows.spPaypalTracking{Versand,Lieferschein}.sql` |
| `history/spArticle*.sql` | `sprocs/CustomWorkflows.spArticleAppend{Price,Label}History.sql` + `spArticleUpdateAllHistory.sql` |
| `Workflowaktion_Gebinde_Erstellen.sql` | `sprocs/CustomWorkflows.spGebindeErstellen.sql` |
| `Workflowaktion_Zustandartikel_Lieferant_Setzen.sql` | `sprocs/CustomWorkflows.spZustandartikelLieferantSetzen.sql` |
| `*_Tests.sql`, `Duplikaterkennung_Bestellungen_Teardown.sql` | `db-migrations/tests/eazybusiness/*.sql` (ported) |

## New actions (created directly in `db-migrations/`, no legacy source)

Custom actions authored after the D12 cut-over live only in the grate chain — they have
no `WorkflowProcedures/*` provenance and are therefore **not** in the table above.

| Action proc | Display name (Wawi picker) | Workflow object | Manual Wawi linkage |
|---|---|---|---|
| `db-migrations/eazybusiness/sprocs/CustomWorkflows.spVpeCheckLieferantenbestellung.sql` | „VPE-Check Warenbestellung" | Lieferantenbestellung (Warenbestellung) | Create a workflow on the **„Warenbestellung geändert"** event and add the action `spVpeCheckLieferantenbestellung`; the Wawi passes `kLieferantenBestellung` automatically. This repo deploys only the proc, not the `dbo.tWorkflow*` config. |

## Not migrated (intentionally)

Ad-hoc / experimental scripts stay here and are not part of the deploy chain:
`Diagnose_Workflow.sql`, the `Workflowaktion Auftrag Preise auf Null*.Sql` and
`Workflowaktion Artikel Seriennummern Standardlager auf WMS*.Sql` variants,
`PayPal/Test/*`, `PayPal/Enable OLE Procedures.sql`.

> [!NOTE]
> The `CustomWorkflows._CheckAction` / `_SetActionDisplayName` calls in the original
> action scripts target objects **provided by the JTL "Custom Workflow Actions"
> module**, not by this repo. The ported migrations therefore do not create those
> helpers; they call them **guarded**. Booking the module (+ Wawi restart + license
> refresh) is a prerequisite — see `docs/SQL/JTL-CUSTOM-WORKFLOWS.md` and
> `db-migrations/README.md` §6.
