# JTL-Wawi Custom Workflows — Architecture & Custom Workflow Actions

> Status: Research / reference document
> Scope: how JTL-Wawi workflows (event → condition → action (Ereignis → Bedingung → Aktion)) work, with a deep focus on **Custom Workflow Actions** (the `CustomWorkflows` SQL schema), how a custom action is discovered/registered/parameterised/invoked, and the definitive answer to "can an action return a gating boolean?".
>
> Two evidence classes are kept strictly separate throughout:
> - **[DB]** — verified against the live `eazybusiness` test database (object definitions, table contents, live workflow rows). This is the primary, authoritative source for the `CustomWorkflows` infrastructure.
> - **[WEB]** — JTL-Guide / forum statements. Used for licensing, UI behaviour, and intent that the DB cannot show.
> - **[INFER]** — conclusions/assumptions drawn by combining the above. Explicitly flagged.
>
> The JTL-Wawi UI is German; the original German concept labels (Ereignis, Bedingung, Aktion, Workflowobjekt, erweiterte Eigenschaft) are given in parentheses on first use so the reader can locate them in the UI.

---

## 1. Overview & scope

JTL-Wawi ships an **event-driven workflow engine**. A workflow (`dbo.tWorkflow`) binds:

1. an **event / trigger (Ereignis / Auslöser)** on a **workflow object (Workflowobjekt)** (Auftrag, Artikel, Lieferschein, …),
2. zero or more **conditions (Bedingungen)** that gate whether the actions run,
3. one or more **actions (Aktionen)** that are executed when the conditions are met.

Out of the box, JTL provides a fixed catalogue of built-in actions (set value, send mail, create exchange order, add to purchase list, …). The separately-licensed **Custom Workflow Actions** module adds the ability to call **your own SQL stored procedures** as actions, registered in a dedicated `CustomWorkflows` database schema ([WEB] forum: "Es gibt ein Modul | Custom Workflow Actions, das man separat buchen muss"; introduced in JTL-Wawi 1.6).

This document is anchored on the `CustomWorkflows` schema as it exists in this repo's target database (`eazybusiness`), cross-checked against the JTL-Guide and the JTL support forum.

---

## 2. Architecture: event → condition → action (Ereignis → Bedingung → Aktion)

[WEB] JTL-Guide *Einleitung zur Workflow-Verwaltung*:
> "Wählen Sie ein auslösendes Ereignis (z. B. Auftrag_Erstellt), definieren Sie optional eine oder mehrere Bedingungen (z. B. Zahlstatus: Ist Bezahlt) und bestimmen eine oder mehrere Aktionen."

For multiple conditions the UI lets you choose whether **all**, **only one**, or **none** must be satisfied ([WEB]: "ob alle Bedingungen erfüllt, nur eine Bedingung erfüllt oder keine Bedingungen erfüllt sein müssen").

### Native storage tables [DB]

Verified column structures (`INFORMATION_SCHEMA.COLUMNS`) of the native engine tables in schema `dbo`:

| Table | Purpose | Key columns [DB] |
|---|---|---|
| `dbo.tWorkflow` | the workflow header | `kWorkflow`, `cName`, `nEvent`, `nObjekt`, `nVerknuepfung` (AND/OR/NONE link of conditions), `nTyp`, `nApplikation`, scheduler fields (`nSchedulerOptions`, `dtSchedulerTime`, `nSchedulerHour/Minute/DayValue/MonthValue`) |
| `dbo.tWorkflowEvent` | catalogue of available events per workflow object | `kWorkflowEvent`, `nEvent`, `nObjekt`, `cDisplayName`, `nSortierung` |
| `dbo.tWorkflowEventGroup` / `tWorkflowEventGroupMapping` | groups events in the UI tree | `kWorkflowEventGroup`, `nObjekt`, `cDisplayName`; mapping joins group↔event |
| `dbo.tWorkflowBedingung` | a single condition of a workflow | `kWorkflowBedingung`, `kWorkflow`, `cEigenschaft` (XML PropertyProxy path), `nOperator`, `cVergleichswert`, `kWorkflowEigenschaft`, `nPos` |
| `dbo.tWorkflowEigenschaft` | reusable **advanced property (erweiterte Eigenschaft)** | `kWorkflowEigenschaft`, `cDotLiquid` (the DotLiquid/SQL template), `cName`, `nObjekt`, `nDatenTyp` (return type) |
| `dbo.tWorkflowAktion` | a single action of a workflow | `kWorkflowAktion`, `kWorkflow`, `xXmlObjekt` (serialised .NET action config), `nPos`, `cName` |
| `dbo.tWorkflowQueue` | pending/queued workflow executions | `kWorkflowQueue`, `nEvent`, `kWorkflow`, `kObjektPk`, `kBenutzer`, `dStartDate`, `nStatus` |
| `dbo.tWorkflowLog` | execution log | `kWorkflowLog`, `kObjektPk`, `kWorkflowAktion`, `dDatum`, `kBenutzer`, `nTyp`, `cLog`, `kWorkflow`, `uniqueId` |

`nTyp` on `tWorkflow` has values `0` (121 rows) and `2` (29 rows) in this DB [DB] — [INFER] `0` = event-triggered, `2` = scheduler/queue-driven (consistent with the scheduler columns and `tWorkflowQueue`). Not independently confirmed from web.

### Events for Aufträge [DB]

`tWorkflowEvent` keys events by `nObjekt` (the workflow object id — see §7) and `nEvent`. Counts per object in this DB [DB]: Artikel(1)=11, Kunde(5)=3, **Auftrag(6)=26**, Lieferschein(7)=8, Rechnung(8)=1, Gutschrift(9)=1, Pickliste(10)=2, plus objects 15 and 16.

The `cDisplayName` values for Auftrag events in this DB are **customer-defined workflow names**, not the canonical JTL event names (e.g. "Unbezahlt Mahnung und Storno in 7 Tagen", "Geändert oder Erstellt", "Interner Auftrag"). [INFER] The shipped/native event for "order created or changed" is what JTL labels "Auftrag_Erstellt" / "Auftrag_Geändert" in the UI ([WEB] guide example uses "Auftrag_Erstellt"); the rows here are this business's configured triggers layered on those base events.

### How a condition produces a truth value [DB][WEB]

A condition (`tWorkflowBedingung`) references a property path (`cEigenschaft`, an XML `<Properties><Property parentType=… propertyName=…/></Properties>` chain), an `nOperator`, and a `cVergleichswert`. Two patterns are visible in this DB [DB]:

1. **Direct property comparison** — e.g. compares `…Zahlungsart.cName` to the literal `Rechnung` (operator `13`).
2. **Reference to an advanced property** — the property path points at `propertyName="_workflowEigenschaft"` + a `jtlWorkfloweigenschaft` id, i.e. the condition evaluates a row from `tWorkflowEigenschaft` and compares the result against `True`/`wahr`.

The advanced property is where DotLiquid (and SQL) live (see §6). Its **return type** is `tWorkflowEigenschaft.nDatenTyp`; in this DB [DB] the distinct values are `0` (text/string, 4 rows), `1` (number, 1 row), `3` (boolean, 30 rows). This matches [WEB] forum statements that an advanced property has a configurable return type (Boolean / Number / Decimal / Text). The condition is satisfied when the operator comparison against the property's rendered value holds.

> [!IMPORTANT]
> **Gating happens at the condition / advanced-property layer, not at the action layer.** This is the crux of §5.

---

## 3. Custom Workflow Actions — licensing, requirements, the `CustomWorkflows` schema

### Licensing & requirements [WEB]

- **Separate module.** Custom Workflow Actions must be booked separately in the JTL Kundencenter license management. [WEB] forum *"CustomWorkflow erscheint nicht in den Workflow-Aktionen"*: the resolution was *"Es gibt ein Modul | Custom Workflow Actions, das man separat buchen muss."*
- **Restart + license refresh** after booking (*"Wawi neu gestartet, Lizenz aktualisiert"*) before the custom actions appear in the UI ([WEB], same thread).
- **Available since JTL-Wawi 1.6** ([WEB] forum/guide). The oldest custom action XML in this DB carries `<WawiVersion>1.6.44.2</WawiVersion>` [DB], consistent with that.
- The procedure must execute against the **business database** (`eazybusiness`), not `master` — a common forum pitfall ([WEB] *"custom-workflows-anlegen"*).

### The `CustomWorkflows` schema infrastructure [DB]

Full object inventory of the schema in this DB (`sys.objects` where `schema_id = SCHEMA_ID('CustomWorkflows')`) [DB]:

**Infrastructure (underscore-prefixed helpers + metadata views/tables):**

| Object | Type | Role |
|---|---|---|
| `CustomWorkflows._CheckAction` | proc | Validates a candidate action SP; raises descriptive errors if it cannot be registered. |
| `CustomWorkflows._SetActionDisplayName` | proc | Sets the action's UI label via the `DisplayName` extended property on the procedure. |
| `CustomWorkflows._SetActionParameterDisplayName` | proc | Sets a parameter's UI label via the `DisplayName` extended property on a **user-defined type**. |
| `CustomWorkflows.vCustomActionParameter` | view | Flattens each SP's parameters (position, name, datatype, display name). |
| `CustomWorkflows.vCustomActionCheck` | view | Per-SP validity check; computes `Status = 'OK' / 'ERROR'`. |
| `CustomWorkflows.vCustomAction` | view | The list JTL consumes: `vCustomActionCheck` filtered to `Status = 'OK'`. |
| `CustomWorkflows.tWorkflowObjects` | table | The 15 supported workflow objects and their PK columns (see §7). |
| `CustomWorkflows.tAllowedDatatypes` | table | The 11 allowed SQL parameter datatypes. |

**Custom actions registered in this DB** (the `sp*` procedures) [DB] — these are this business's own actions, e.g. `spAuftragPreiseAufNull`, `spArticleUpdateAllHistory`, `spGebindeErstellen`, `spPaypalTrackingLieferschein/Versand`, `spSeriennummerStandardZuWMS`, `spCMArtikel`.

#### `_CheckAction` — exact behaviour [DB]

`OBJECT_DEFINITION('CustomWorkflows._CheckAction')` (paraphrased faithfully): it reads one row from `vCustomActionCheck` for `@actionName` and, **if `Status = 'ERROR'`**, raises the specific reason(s) via `RAISERROR(..., 11, 0)`:

- `nParamCount > 7` → `'Es dürfen neben dem Parameter für den PK maximal 6 weitere Parameter angegeben werden'` (so: 1 PK + up to 6 = **7 parameters max**).
- `cNotAllowedParamTypesInAction IS NOT NULL` → `'Nicht erlaubte Datentypen in den Parametern der Aktion gefunden'`, then **prints the allowed list** by cursoring over `tAllowedDatatypes`.
- `nObject IS NULL` → `'PK-Spalte muss erster Parameter der Aktion sein'`, then prints *"Über den ersten Parameter der Aktion wird bestimmt, für welches Workflowobjekt diese Aktion verwendet werden kann. Dieser muss vom Typ "int" sein"* and cursors over `tWorkflowObjects` to print each object + its PK column. (The message states that the first parameter determines which workflow object the action applies to and must be of type "int".)

So `_CheckAction` is a **developer-facing validator**: it does not register anything; it just tells you why your SP would be rejected. The actual "registration" is purely structural (see §4) — the SP becoming valid is a side effect of meeting the rules the views encode. `_CheckAction` produces **no error and no message when the SP is already valid** (the `IF @status = 'ERROR'` block is skipped). [DB]

#### `_SetActionDisplayName` — exact behaviour [DB]

For an SP `@actionName` in schema `CustomWorkflows`, it drops any existing `DisplayName` extended property on that procedure and adds `sp_addextendedproperty @name='DisplayName', @value=@displayName, @level0type='SCHEMA', @level0name='CustomWorkflows', @level1type='PROCEDURE', @level1name=@actionName`. That is the label shown in the JTL action picker. [DB] Verified live: `spAuftragPreiseAufNull` has `DisplayName = 'Auftrag Preise auf Null setzen'`.

#### `_SetActionParameterDisplayName` — exact behaviour [DB]

This one operates on a **user-defined type**, not on the procedure. It checks for / drops an existing `DisplayName` extended property where `class_desc = 'TYPE'` and `userTypes.name = @parameterName`, then adds the `DisplayName` extended property at `@level1type='TYPE', @level1name=@parameterName`. See §6 for the full mechanic.

---

## 4. How a custom action is discovered, registered, parameterised, and invoked

### 4.1 Discovery — what makes an SP appear as an action [DB]

JTL reads `CustomWorkflows.vCustomAction`, which is `vCustomActionCheck WHERE Status = 'OK'`. The full chain (all verified from `OBJECT_DEFINITION`) [DB]:

**`vCustomActionParameter`** enumerates every parameter of every SP in schema `CustomWorkflows` whose name does **not** start with `_` (`prd.name NOT LIKE '\_%' ESCAPE '\'`). Per parameter it derives:
- `nPos` = `parameter_id - 1` (so the **first SQL parameter is position 0**),
- `cName` = parameter name with `@` stripped,
- `cDataType` = the SQL type **only if it matches `tAllowedDatatypes`** (LEFT JOIN → `NULL` for a disallowed type),
- `cDisplayName` = the `DisplayName` extended property of the parameter's **user-defined type**, falling back to the stripped parameter name.

**`vCustomActionCheck`** then builds three CTEs over those parameters:
- `PkParams` — joins parameter **position 0** of type **`int`** against `tWorkflowObjects.cPkColumn`. A match yields the workflow object (`nObjekt`, `cObjekt`, `cPkCol`). This is the **PK-first rule**.
- `NotAllowedParamTypes` — any parameter with `cDataType IS NULL` (i.e. a type not in `tAllowedDatatypes`).
- `ParamCounts` — total parameter count per SP.

`Status` is `'ERROR'` when **any** of: no PK match (`cObjekt IS NULL`), a disallowed parameter type exists, or `nParamCount > 7`; otherwise `'OK'`.

It also pulls three procedure-level extended properties: `DisplayName`, `Description`, `VersionCode`.

> [!NOTE]
> **There is no install/registration step.** An SP "registers" itself simply by existing in the `CustomWorkflows` schema and satisfying the three rules. `_CheckAction`/`_SetActionDisplayName` are convenience/validation/labelling helpers, not a registry. [INFER from the view definitions — no registry table exists in the schema; the only tables are the static `tWorkflowObjects`/`tAllowedDatatypes`.]

### 4.2 The three structural rules a custom action SP must satisfy [DB]

1. **Schema + name** — in `CustomWorkflows`, name not starting with `_`.
2. **PK-first rule** — the **first** parameter (position 0) must be of type **`int`** and be **named exactly like the PK column** of one of the 15 workflow objects in `tWorkflowObjects` (e.g. `@kAuftrag`, `@kArtikel`, `@kLieferschein`). That first parameter both (a) determines which workflow object the action attaches to and (b) is auto-filled by JTL at runtime with the triggering object's PK.
3. **Datatypes + count** — every parameter type ∈ `tAllowedDatatypes`; total parameters ≤ 7 (1 PK + ≤ 6 extra).

[WEB] confirms the PK-first rule from the troubleshooting angle: a user whose action did not appear had used `cAuftragsNr` instead of `kAuftrag` ([WEB] *"CustomWorkflow erscheint nicht…"*).

### 4.3 Parameterisation & invocation — verified from live action XML [DB]

A custom action is stored in `dbo.tWorkflowAktion.xXmlObjekt` as a serialised .NET object with `i:type="a:jtlAktionCustomWorkflow"`. Two live examples from this DB [DB]:

No extra params (`spAuftragPreiseAufNull`):
```xml
<jtlAktion ... i:type="a:jtlAktionCustomWorkflow">
  <CancelOnError>false</CancelOnError>
  <WawiVersion>1.6.44.2</WawiVersion>
  <a:UseDotLiquidParameters>false</a:UseDotLiquidParameters>
  <a:ActionName>spAuftragPreiseAufNull</a:ActionName>
  <a:ActionParameter .../>           <!-- empty: PK (@kAuftrag) is implicit -->
</jtlAktion>
```

With an extra DotLiquid-filled param (`spArticleUpdateAllHistory`, which has `@kArtikel int` + `userName nvarchar`):
```xml
<jtlAktion ... i:type="a:jtlAktionCustomWorkflow">
  <CancelOnError>false</CancelOnError>
  <a:ActionName>spArticleUpdateAllHistory</a:ActionName>
  <a:ActionParameter ...>
    <b:KeyValueOfintCustomActionParameters...>
      <b:Key>1</b:Key>                <!-- parameter position 1 (the second SQL param) -->
      <b:Value>
        <c:Name>userName</c:Name>
        <c:Pos>1</c:Pos>
        <c:UseDotLiquid>true</c:UseDotLiquid>
        <c:Value i:type="d:string">{{ AktuellerBenutzer.Login }}</c:Value>
      </b:Value>
    </b:KeyValueOfintCustomActionParameters...>
  </a:ActionParameter>
</jtlAktion>
```

Key observations [DB]:
- The **PK parameter (position 0) is not present** in `ActionParameter` — JTL supplies it implicitly from the triggering object. Only the **extra** parameters (position ≥ 1) are configured in the UI and serialised.
- Each configured parameter can be a literal **or** a **DotLiquid expression** (`UseDotLiquid=true`, e.g. `{{ AktuellerBenutzer.Login }}`), rendered against the Vorgang context before the SP is called.
- `CancelOnError` ([WEB]: the "Bei Fehler Workflow abbrechen" checkbox) controls whether a failure of this action aborts the remaining workflow.

[INFER] At runtime JTL therefore executes `EXEC CustomWorkflows.<ActionName> @<pk>=<objectPk>, @<extra>=<rendered value>, …`. The engine does not read any RETURN/OUTPUT (see §5).

---

## 5. Conditions vs. actions — can an action return a gating boolean?

**Definitive answer: No. A custom action cannot return a value that steers the workflow. Gating is the job of a condition / advanced property, evaluated *before* the actions run.**

Evidence:

- **[DB] The metadata layer has no concept of a return/OUTPUT.** `vCustomActionParameter` enumerates `sys.parameters` including the implicit return parameter, but `vCustomActionCheck` only ever uses parameters by **position and input type** (PK-first, allowed-types, count). `_CheckAction` raises errors purely about parameters; nothing reads a RETURN value or an OUTPUT parameter, and nothing maps such a value back into `tWorkflow*`. There is no column anywhere in `CustomWorkflows.*` or `dbo.tWorkflow*` that stores an action's result for gating. An OUTPUT parameter would simply count toward the 7-parameter budget and (if its type is allowed) be treated as an input slot — its written-back value is ignored by the engine. [INFER, but tightly grounded in the absence of any consuming structure.]
- **[DB] The action XML (`jtlAktionCustomWorkflow`) carries only inputs and `CancelOnError`** — there is no "branch on result" element. The only control an action exposes over the workflow is the binary "abort-on-error" flag.
- **[WEB] Control flow lives in conditions via advanced properties with a Boolean return type.** Forum *"Erweiterte Eigenschaften Rückgabewert Boolean"*: an advanced property is configured with return type **Boolean** and a DotLiquid body such as `{% if … %} true {% else %} false {% endif %}`; that property is then used as a workflow **condition** to gate execution. Return types offered are Boolean / Number / Decimal / Text. ([WEB] also notes a caveat that the engine internally string-compares the rendered value — "convert Boolean to String = String" — so robust conditions compare against the literal `true`/`True`.)
- **[DB] Confirms the same shape:** `tWorkflowEigenschaft.nDatenTyp` distinct values `0`/`1`/`3` (text/number/boolean), with 30 of the 34 rows being boolean (`nDatenTyp = 3`) — exactly the gating use-case. Conditions reference these via `tWorkflowBedingung.kWorkflowEigenschaft` / the `_workflowEigenschaft` property path.

**Contradiction note:** none found between DB and WEB. Both agree gating is a condition-layer concern; the action layer only writes side effects + optionally aborts on error.

> [!WARNING]
> A common misconception is to write a "validation" custom action that `RETURN`s 0/1 expecting JTL to branch. It will not. To gate on a SQL computation, put the SQL in an **advanced property** (SELECT-only, returns a string/boolean) and use it as a **condition**, not as an action.

---

## 6. DotLiquid & SQL / advanced conditions

[WEB] JTL-Guide: DotLiquid is the templating/expression language across templates and workflows — *"Dabei bietet Ihnen die Programmiersprache DotLiquid die Möglichkeit, mit wenigen einfachen Befehlen und Funktionen, individuelle Lösungen … einzurichten."*

**Advanced properties (erweiterte Eigenschaften):** reusable named expressions (`tWorkflowEigenschaft`) [DB] that can:
- access the full DotLiquid `Vorgang.*` object graph (e.g. `Vorgang.Zahlungen.Zahlungsart.Name`, `Vorgang.Artikel.Bestandsübersicht.Verfügbar`),
- run loops/conditionals, and
- **execute SQL** ([WEB] forum: SQL is allowed, with great query flexibility, but **INSERT/UPDATE/DELETE are not permitted** — SELECT only; an advanced property always returns a **string** which is then coerced to the configured return type).

Live DotLiquid bodies in this DB (`tWorkflowEigenschaft.cDotLiquid`) [DB] illustrate both pure-DotLiquid and conditional-boolean patterns, e.g.:
```liquid
{% if Vorgang.Artikel.Bestandsübersicht.Verfügbar < Vorgang.Artikel.Allgemein.Lager.Mindestbestand %}True{% endif %}
```
```liquid
{% if Vorgang.Zahlungen.Lieferadresse.Straße == Vorgang.Zahlungen.Rechnungsadresse.Straße %}
true
{% else %}
false
{% endif %}
```

**Return-type pitfalls** [WEB]:
- Arithmetic conditions must use return type **Decimal** (not Number, which expects integers) to avoid formatting errors (forum *"Workflow erweiterte Eigenschaften"*).
- Boolean conditions are string-compared internally; compare against the literal you actually emit (`true`/`True`).

DotLiquid is also used **inside custom-action parameters** (see §4.3, `UseDotLiquid=true`), so the same expression language fills both condition and action parameter values.

---

## 7. Workflow objects table (full `tWorkflowObjects` list)

Complete content of `CustomWorkflows.tWorkflowObjects` [DB] (columns: `nObjekt int`, `cName nvarchar(100)`, `cPkColumn nvarchar(100)`). The **`cPkColumn` is the exact name your action SP's first `int` parameter must have**:

| nObjekt | cName | cPkColumn (→ required first param) |
|---:|---|---|
| 1 | Artikel | `kArtikel` |
| 2 | WarenlagerAusgang | `kWarenLagerAusgang` |
| 3 | Lieferantenbestellung | `kLieferantenbestellung` |
| 4 | Eingangsrechnung | `kEingangsrechnung` |
| 5 | Kunde | `kKunde` |
| 6 | Auftrag | `kAuftrag` |
| 7 | Lieferschein | `kLieferschein` |
| 8 | Rechnung | `kRechnung` |
| 9 | Gutschrift | `kGutschrift` |
| 10 | Pickliste | `kPickliste` |
| 11 | WarenlagerEingang | `kWarenlagerEingang` |
| 12 | Angebot | `kAngebot` |
| 16 | Versand | `kVersand` |
| 18 | Pick | `kPick` |
| 20 | Ticket | `kTicket` |

(15 rows; note the gaps 13/14/15/17/19 are not present.)

Allowed parameter datatypes — full `CustomWorkflows.tAllowedDatatypes` [DB]: `bigint`, `bit`, `date`, `decimal`, `float`, `int`, `money`, `nvarchar`, `real`, `tinyint`, `varchar` (11 types).

---

## 8. Practical recipe: skeleton of a custom action SP recognised by JTL

The minimal, DB-verified pattern (modelled on the live `spAuftragPreiseAufNull` and the forum examples). Run against **`eazybusiness`**, not `master`:

```sql
USE eazybusiness;
GO

-- 1) The action. First parameter MUST be the PK of a tWorkflowObjects row,
--    of type int, named exactly like cPkColumn (here: Auftrag -> @kAuftrag).
CREATE OR ALTER PROCEDURE CustomWorkflows.spAuftragBeispielAktion
    @kAuftrag INT,                 -- pos 0: PK, auto-filled by JTL at runtime
    @hinweis  NVARCHAR(255) = NULL -- pos 1..6: optional extra params, allowed types only
AS
BEGIN
    SET NOCOUNT ON;
    -- side-effect logic only; do NOT rely on RETURN/OUTPUT to gate the workflow
    UPDATE Verkauf.tAuftrag
       SET cAnmerkung = ISNULL(@hinweis, cAnmerkung)
     WHERE kAuftrag = @kAuftrag;
END;
GO

-- 2) Validate. Prints nothing if the SP is valid; raises a descriptive error otherwise
--    (PK-first violation, disallowed datatype, or >7 params).
EXEC CustomWorkflows._CheckAction @actionName = 'spAuftragBeispielAktion';
GO

-- 3) Label shown in the JTL action picker (DisplayName extended property on the proc).
EXEC CustomWorkflows._SetActionDisplayName
     @actionName  = 'spAuftragBeispielAktion',
     @displayName = 'Auftrag: Beispiel-Hinweis setzen';
GO

-- 4) (Optional) Friendly label for an EXTRA parameter. This works via a USER-DEFINED TYPE:
--    create a type, use it as the parameter's type, then label the TYPE.
--    Without a user-defined type, the parameter label defaults to the @-stripped name.
CREATE TYPE CustomWorkflows.Param_Hinweis FROM NVARCHAR(255);
GO
EXEC CustomWorkflows._SetActionParameterDisplayName
     @parameterName = 'Param_Hinweis',     -- the user-defined TYPE name
     @displayName   = 'Anzuhängender Hinweistext';  -- the label shown in the JTL UI
GO
-- then declare the extra param AS CustomWorkflows.Param_Hinweis instead of NVARCHAR(255).
```

After this, refresh in JTL-Wawi (and ensure the **Custom Workflow Actions** module is licensed + Wawi restarted). The action appears for workflow object *Auftrag*, parameterisable in the workflow editor; JTL fills `@kAuftrag` with the triggering order's PK and renders any DotLiquid you put in `@hinweis`.

> [!NOTE]
> **Parameter display names need user-defined types.** [DB] In *this* DB no user-defined types exist in `CustomWorkflows`, so every live extra parameter (e.g. `userName`) shows its raw name as `cDisplayName`. `_SetActionParameterDisplayName` only takes effect when the parameter is typed with a user-defined type that carries the `DisplayName` extended property — see step 4.

---

## 9. Sources

### (a) Database objects — primary source (`eazybusiness`, verified via `OBJECT_DEFINITION` / table reads)

| Object (Schema.Name) | What it proves |
|---|---|
| `CustomWorkflows._CheckAction` | Validation rules + exact German error strings (PK-first, ≤7 params, allowed types). |
| `CustomWorkflows._SetActionDisplayName` | Action label = `DisplayName` extended property on the procedure. |
| `CustomWorkflows._SetActionParameterDisplayName` | Parameter label = `DisplayName` extended property on a **user-defined type**. |
| `CustomWorkflows.vCustomActionParameter` | Parameter flattening: `nPos = parameter_id-1`, datatype gated by `tAllowedDatatypes`, display-name fallback. |
| `CustomWorkflows.vCustomActionCheck` | The `OK/ERROR` logic: PK-first match, disallowed-type, count>7; pulls DisplayName/Description/VersionCode. |
| `CustomWorkflows.vCustomAction` | The action list JTL consumes (`Status='OK'`). |
| `CustomWorkflows.tWorkflowObjects` | 15 workflow objects + their PK columns (§7). |
| `CustomWorkflows.tAllowedDatatypes` | 11 allowed parameter datatypes. |
| `CustomWorkflows.spAuftragPreiseAufNull` (+ siblings) | Live custom-action SP shape (`@kAuftrag INT` first param). |
| `dbo.tWorkflow`, `tWorkflowAktion`, `tWorkflowBedingung`, `tWorkflowEigenschaft`, `tWorkflowEvent(+Group/Mapping)`, `tWorkflowQueue`, `tWorkflowLog` | Native engine structure; live `jtlAktionCustomWorkflow` XML proving implicit-PK + DotLiquid params + `CancelOnError`; `nDatenTyp` boolean return types for gating. |

### (b) Web sources

- [JTL-Guide — Einleitung zur Workflow-Verwaltung](https://guide.jtl-software.com/jtl-wawi/jtl-workflows/einleitung-zur-workflow-verwaltung/) — event/condition/action model; AND/OR/NONE condition combination; DotLiquid as the extensibility layer; `Auftrag_Erstellt` example.
- [JTL-Guide — JTL-Workflows (overview)](https://guide.jtl-software.com/jtl-wawi/jtl-workflows/) — workflow automation overview.
- [JTL-Guide — Allgemeine Beispiele für DotLiquid](https://guide.jtl-software.com/jtl-wawi/vorlagen/allgemeine-beispiele-fuer-dotliquid/) — DotLiquid syntax reference.
- [Forum — CustomWorkflow erscheint nicht in den Workflow-Aktionen](https://forum.jtl-software.de/threads/customworkflow-erscheint-nicht-in-den-workflow-aktionen.240151/) — **separate "Custom Workflow Actions" module must be booked + Wawi restart + license refresh**; PK-first gotcha (`cAuftragsNr` vs `kAuftrag`); schema must be `CustomWorkflows`.
- [Forum — Custom Workflows anlegen](https://forum.jtl-software.de/threads/custom-workflows-anlegen.188254/) — full SQL example (`spArtikelUeberverkaeufeDeaktivieren @kArtikel INT`, `_CheckAction`, `_SetActionDisplayName`); must run against `eazybusiness` not `master`.
- [Forum — eigene CustomWorkflows anlegen](https://forum.jtl-software.de/threads/eigene-customworkflows-anlegen.216028/) — skeleton incl. `CREATE TYPE` + `_SetActionParameterDisplayName` for parameter labels; NULL-safety in action body.
- [Forum — Erweiterte Eigenschaften Rückgabewert Boolean](https://forum.jtl-software.de/threads/erweiterte-eigenschaften-rueckgabewert-boolean.172219/) — **gating boolean lives in an advanced property / condition**, return types (Boolean/Number/Decimal/Text), Boolean-as-string caveat.
- [Forum — Workflow erweiterte Eigenschaften](https://forum.jtl-software.de/threads/workflow-erweiterte-eigenschaften.125208/) — DotLiquid arithmetic in conditions; Decimal vs Number return type.
- [Forum — Workflow … DotLiquid-Variablen für „Eigenschaften"](https://forum.jtl-software.de/threads/workflow-dotliquid-variablen-fuer-eigenschaften-implementieren.107532/) — SQL in advanced properties, SELECT-only (no INSERT/UPDATE/DELETE), always returns a string.
- [Forum — Tatsächlichen Rückgabewert einer Abfrage für einen Workflow](https://forum.jtl-software.de/threads/tatsaechlichen-rueckgabewert-einer-abfrage-fuer-einen-worklflow-ausgeben-lassen.124206/) — advanced-property route for surfacing query results into a workflow.

---

## Appendix — facts vs. inference summary

| Claim | Class |
|---|---|
| Action label / parameter datatype gating / PK-first / ≤7 params | **[DB]** verified in `_CheckAction` + views |
| 15 workflow objects + PK columns; 11 allowed datatypes | **[DB]** full table content |
| Custom action stored as `jtlAktionCustomWorkflow` XML; PK implicit; extra params support DotLiquid; `CancelOnError` | **[DB]** live `tWorkflowAktion.xXmlObjekt` |
| Separate "Custom Workflow Actions" module, since 1.6, needs restart + license refresh, run on `eazybusiness` | **[WEB]** forum/guide |
| Gating boolean belongs to condition / advanced property, not action; return types Boolean/Number/Decimal/Text; SQL SELECT-only in properties | **[WEB]** + **[DB]** (`nDatenTyp`) — both agree |
| Action OUTPUT/RETURN is ignored by the engine | **[INFER]** — grounded in absence of any consuming structure in DB + action XML |
| `tWorkflow.nTyp` 0=event / 2=scheduler | **[INFER]** from column semantics; not web-confirmed |
| No registry step — discovery is purely structural via the views | **[INFER]** from view definitions (no registry table exists) |
