# Oracle Reports XML Report Definition — Syntax Reference

Knowledge reference for the Reports XML Report Definition format (the
`<report>`/`report.dtd` format used by `rwconverter stype=xmlfile`), kept
separate from the test-module status doc so it can be reused for debugging
any Reports XML file, not just the two demo reports in this directory.

Sources, in order of authority:

1. **`$ORACLE_HOME/reports/dtd/reports.dtd`** (1688 lines) and
   **`distribution.dtd`** (65 lines) — the actual DTDs this FMW 14.1.2
   installation ships and validates against
   (`/u01/app/oracle/fmw/reports/dtd/` on this host). This is the ground
   truth for element/attribute names, defaults and required-ness — not
   Oracle's prose docs, which lag behind and sometimes describe older
   releases.
2. Oracle doc [Debugging XML Report Definitions (12.2.1.3)](https://docs.oracle.com/middleware/12213/formsandreports/use-reports/pbr_xml005.htm) —
   thin on syntax, but confirms `<report name=... author=... DTDVersion="9.0.2.0.0">`
   and gives `rwbuilder REPORT=...xml` / `CUSTOMIZE=...xml` as ways to
   open/validate an XML definition in Reports Builder for debugging.
3. Oracle doc [About Distribution XML Files (11g)](https://docs.oracle.com/middleware/11119/classic/use-reports/pbr_dist003.htm) —
   confirms `distribution.dtd` governs a *separate* kind of XML file (output
   distribution — mail/file/printer destinations), not the report definition
   itself; see [Distribution XML](#distribution-xml--distributiondtd) below.
4. A real, presumably-working production report (`90-Source-MetaData/TNQ.xml`)
   — read and its structure mapped out for usage patterns the DTD alone
   doesn't show (which attributes are actually used together in practice,
   bind vs. lexical parameter style, parameter-form field/text layout). No
   content from that file is reproduced here (it contains real customer
   business logic/field names — see `CLAUDE.md`, "No customer names in
   committed code").

> **Status:** element/attribute names and content models below are DTD-
> confirmed (source 1) — these will validate. Which combinations actually
> *convert and run* correctly in Reports (e.g. whether `canParse="no"` is
> needed for a given query, exact parameter-form geometry) is still only
> example-derived (source 4) and **not yet confirmed by actually
> converting/running a report in this project** — see
> `09-Install/docs/20-forms_reports_testmodules.md`.

---

## Root Element

Per `reports.dtd` (`<!ELEMENT report (xmlSettings | comment? | reportHtmlEscapes
| data | layout | parameterForm | programUnits | attachedLibrary |
destination* | customize | webSource | colorPalette | reportPrivate |
accessibility | documentTaxonomy | userStyle | reportWebSettings |
characterMode)*>`): **`<data>`, `<layout>` and `<parameterForm>` are three
independent, optional children of `<report>` — siblings, none nested in
another.** This is DTD-confirmed, not just an observation from one example.

```xml
<report name="REPORT_NAME" DTDVersion="9.0.2.0.0">
```

`DTDVersion` is the only `#REQUIRED` attribute. All others are `#IMPLIED`
(optional): `name`, `title`, `author`, `beforeParameterFormTrigger`,
`afterParameterFormTrigger`, `beforeReportTrigger`, `betweenPagesTrigger`,
`afterReportTrigger`, `unitOfMeasurement` (`inch|centimeter|point`),
`previewerTitle`, `designInCharacterUnits` (`yes|no`, default `no`), plus a
family of `xmlTag*`/`xmlPrologType`/`xmlPrologValue`/`xmlPrologFile`
attributes for a custom XML output prolog (only relevant if the report
itself emits XML, not for a plain PDF/HTML report).

- `DTDVersion="9.0.2.0.0"` is what Oracle's own debugging-doc example uses,
  and is documented as valid through 11g/12c.
- `9.0.2.0.10` is the version actually seen in use together with
  `<userParameter>`/`<parameterForm>` (see `test_user_objects.xml`) — if a
  report with parameters fails to convert under `9.0.2.0.0`, try `9.0.2.0.10`.
  The DTD itself does not restrict `DTDVersion` to an enumerated list (it's
  plain `CDATA`), so this is a convention, not a DTD constraint.
- The DTD ships with the installation: `$ORACLE_HOME/reports/dtd/reports.dtd`
  (not `report.dtd` — singular `report.dtd` does not exist on this host).

## `<data>` — Queries and Parameters

```xml
<data>
  <userParameter .../>
  <systemParameter .../>
  <dataSource name="Q_1" maxRows="...">
    <select>...</select>
  </dataSource>
</data>
```

- `<!ELEMENT dataSource ((select | plugin | plsqlStatement), comment?,
  displayInfo?, formula*, group*)>` — `<select>` is only one of three
  possible query sources; `<plugin>` (JDAPI custom data source class) and
  `<plsqlStatement>` (PL/SQL-returned ref cursor) are the others, not covered
  further here.
- `<dataSource name= defaultGroupName= maxRows=>` — **all three attributes
  are `#IMPLIED` (optional)**, including `name` itself, though every example
  seen in practice sets it (the layout's `<field source=...>` has nothing to
  bind to otherwise). `maxRows` caps the row count (seen used on a
  single-row lookup query).
- `<!ELEMENT select (#PCDATA)>` with `<!ATTLIST select canParse (yes|no)
  "yes" externalQueryFile CDATA #IMPLIED>` — `canParse="no"` tells Reports
  not to parse the SQL text itself (seen used on a large query with complex/
  dynamic lexical substitution that the built-in parser can't handle).
- Column aliases in the `SELECT` are **mandatory** for unambiguous column
  names, and are what `source=` in `<layout>` references. Avoid reserved
  words as aliases (e.g. `current_date` breaks — see `test_dual.xml`'s header
  comment for the concrete trap).

### `<userParameter>`

DTD: `<!ELEMENT userParameter (comment?, listOfValues?)>`, attributes `name`
(`#REQUIRED`), `datatype` (`number|character|date`, **default `number`** —
easy to forget, `test_user_objects.xml`'s `P_OBJECT_NAME` needs
`datatype="character"` explicitly), `pluginClass`, `width` (default `"20"`),
`scale`/`precision` (default `"0"` each), `initialValue`, `inputMask`,
`validationTrigger`, `label`, `defaultWidth`, `defaultHeight`,
`templateSection` (`none|header|main|trailer`, default `none`), `display`
(`yes|no`, default `yes`).

```xml
<userParameter name="P_NAME" datatype="character" precision="30"
 initialValue="..." label="Human Label" defaultWidth="0" defaultHeight="0"
 display="yes">
  <comment><![CDATA[free-text description, optional]]></comment>
  <listOfValues restrictToList="yes">
    <selectStatement hideFirstColumn="yes">
      <![CDATA[select 'value', 'display label' from dual
UNION ALL select ... ]]>
    </selectStatement>
  </listOfValues>
</userParameter>
```

- `display="no"` hides the parameter from the parameter form entirely (used
  for internal/technical parameters that are still bindable in SQL).
- `<listOfValues>` (`<!ELEMENT listOfValues (staticValues | selectStatement)>`,
  `restrictToList` default `"yes"`) is optional — only needed for a
  dropdown/LOV. `staticValues` is a hardcoded `<validValue value="..."/>*`
  list, the alternative to a `selectStatement` query.

### `<systemParameter>`

DTD: `<!ELEMENT systemParameter (comment?)>`, attributes `name`
(`#REQUIRED`), `initialValue`, `inputMask`, `validationTrigger`, `display`
(`yes|no`, default `yes`) — notably **no `datatype`**: the datatype of a
system parameter is fixed by Reports itself, unlike `<userParameter>`.

```xml
<systemParameter name="MODE" initialValue="Default" display="yes"/>
<systemParameter name="ORIENTATION" initialValue="..." display="yes"/>
```

Overrides one of Reports' built-in system parameters (`DESTYPE`, `DESFORMAT`,
`MODE`, `ORIENTATION`, etc.). **Not required** for a minimal report — Reports
supplies its own defaults for any system parameter not explicitly declared.

### Bind-Variable Styles

Two distinct styles, used for different purposes — do not mix them up:

| Style | Meaning | Use for |
|---|---|---|
| `:PARAMNAME` | SQL bind variable | A single value substituted into a `WHERE`/comparison, e.g. `where object_name like upper(:P_OBJECT_NAME)` |
| `&PARAMNAME` | Lexical (textual) substitution | Dynamic SQL *text*, e.g. an `IN`-list built from a parameter: `where id in (&PARAM_OIDLIST)` |

A lexical parameter (`&...`) is substituted into the SQL text itself before
parsing, so it can change the query's structure (add a clause, build an
`IN`-list) — a bind parameter (`:...`) can only ever be a value.

## `<layout>` — Report Body

```xml
<layout>
  <section name="main">
    <tabular name="M_1">
      <labelAttribute/>
      <field name="F_NAME" source="column_alias" label="Column Label"/>
    </tabular>
  </section>
</layout>
```

- `<!ELEMENT section ((tabular | groupAbove | groupLeftInsideGroupAbove |
  groupLeft | matrix | formLike | field)*, destination*, body?, margin?)>` —
  a section holds exactly one layout style element (plus optional
  destinations/body/margin); `name` is conventionally `header`/`main`/
  `trailer` but the DTD itself doesn't enumerate section names — they're
  `CDATA`, matched by Reports' own convention, not validated by the DTD.
- Layout styles (DTD element names): `tabular`, `groupAbove`,
  `groupLeftInsideGroupAbove`, `groupLeft`, `matrix`, `formLike`. All of
  `tabular`/`groupAbove`/`groupLeft` share the same content model:
  `(labelAttribute?, group*, field*, rowDelimiter*)` plus attributes `name`,
  `hideLabel`, `width`, `height`, `template` (e.g. `"rwbeige.tdf"` from
  `$ORACLE_HOME/reports/templates`), `fillColor`, `lineColor`,
  `addPageToFit` (`yes|no`, default `no`).
- `<!ELEMENT field ((labelAttribute?, exception*) | ((font | comment |
  geometryInfo | visualSettings | webSettings | generalLayout |
  advancedLayout | accessibility)*, pageNumbering?))>` — `name` is the only
  `#REQUIRED` attribute; `source` (the column alias to bind), `label`,
  `formatMask`, `alignment` (`start|left|center|right|end|flush`, default
  `start`), `nullValue`, `breakOrder` are the commonly-used ones.
- Additional elements as needed: `<link>` (master-detail), `<formula>`,
  `<exception>`/`<condition>` (format triggers).
- See `test_dual.xml` for a complete, minimal working example of this block.

## `<parameterForm>` — Parameter Entry Screen

```xml
<parameterForm width="10.00000" height="10.00000">
  <text name="PB_SOME_LABEL" pageNumber="1" minWidowLines="1">
    <textSegment>
      <font face="Courier New" size="11" bold="yes"/>
      <string><![CDATA[Label Text:]]></string>
    </textSegment>
  </text>
  <field name="PF_P_NAME" source="P_NAME" pageNumber="1"
   minWidowLines="1" spacing="0" alignment="start">
    <font size="0"/>
    <geometryInfo x="3.89" y="2.07" width="5.90" height="0.66"/>
  </field>
</parameterForm>
```

- **`<parameterForm>` is a sibling of `<layout>`, not nested inside it** —
  DTD-confirmed: `<report>`'s content model lists `data | layout |
  parameterForm` as independent alternatives of the same repeating group, not
  one nested in another. In a real report it appears directly before
  `</report>`, after `</layout>`.
- `<!ELEMENT parameterForm (field | text | polyline | polygon | rectangle |
  line | linkFile | arc | roundedRectangle | webSettings | accessibility |
  image | rulers)*>`, attributes `width`, `height`, `pages` (all `#IMPLIED`).
  It's a small drawing canvas — the same drawing primitives (`polyline`,
  `rectangle`, `arc`, `image`, ...) available in `<layout>` sections are
  usable here too, not shown above since a minimal form only needs
  `field`/`text`.
- `<field source="...">` links an entry field to a `<userParameter name="...">`
  by name — this is what actually puts the parameter on the entry screen;
  declaring `<userParameter>` alone in `<data>` is not enough for an
  interactive prompt to appear.
- `<text>` elements supply the plain-text labels next to each field; they are
  unrelated to any parameter by name, purely visual.
- `geometryInfo`/`font`/`visualSettings` positioning values are cosmetic —
  any reasonable non-overlapping coordinates work; they don't need to match
  a real layout tool's output exactly for a functional smoke test.

## Distribution XML (`distribution.dtd`)

A **separate** DTD/file kind from the report definition above — governs
*where report output goes after it runs* (mail/file/printer fan-out), not the
report's own data/layout. Confirmed via `$ORACLE_HOME/reports/dtd/
distribution.dtd` (65 lines) plus Oracle's
[About Distribution XML Files](https://docs.oracle.com/middleware/11119/classic/use-reports/pbr_dist003.htm) doc.

```xml
<!ELEMENT destinations ((foreach | mail | file | printer | destype)+)>
```

- `<mail id= to= cc= bcc= from= replyTo= subject= priority=
  returnReceipt=>` — sends the output by mail; `<body>`/`<attach>` children
  control format (`pdf|html|htmlcss|rtf|ascii|xml|delimiteddata|
  spreadsheet|enhancedspreadsheet`).
- `<file id= name= format= instance=>`, `<printer id= name= copies=
  instance=>`, `<destype id= name= format= instance=>` — the other three
  destination kinds, each wrapping one or more `<include src="..."/>`.
- `<foreach>` repeats a destination once per row of a report group (e.g. one
  e-mail per employee) instead of once per report run.
- **Dynamic values**: an attribute like `to=` can reference a report column
  with `&column_name`, or `&<column_name>` when mixed with literal text —
  per Oracle's doc, the ampersand and angle brackets must then be XML-escaped
  (`&amp;`, `&lt;`, `&gt;`) in the attribute value itself, e.g.
  `to="&amp;&lt;CF_MAILID&gt;@mycompany.com"` where `CF_MAILID` is a formula
  column defined in the report. This is a different substitution mechanism
  from the report's own `&PARAMNAME` lexical parameters above — same `&`
  sigil, different file/DTD, different escaping rules.
- Not yet confirmed in this project: how a distribution XML file is actually
  wired to a run (expected to be the `DISTRIBUTIONXML=`/`DISTRIBUTE=`
  parameter on `rwrun`/`rwclient`, per Oracle's docs structure, but neither
  fetched doc page showed the concrete invocation syntax) — out of scope for
  the two demo reports in this directory, which use no distribution XML.

## Further Reading

- `$ORACLE_HOME/reports/dtd/reports.dtd` — the full, authoritative DTD;
  grep it directly for any element/attribute not covered above.
- `$ORACLE_HOME/reports/dtd/distribution.dtd` — the distribution-XML DTD.
- `09-Install/reports_templates/test_dual.xml` — minimal working example,
  no parameters.
- `09-Install/reports_templates/test_user_objects.xml` — minimal working
  example, one parameter + parameter form.
- `90-Source-MetaData/TNQ.xml` — full production-scale example with all
  patterns above in combination (do not copy its business-logic content).
- `09-Install/docs/20-forms_reports_testmodules.md` — overall test-module
  status, open verification points, live test log.
