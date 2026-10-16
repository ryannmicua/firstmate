---
name: output-conventions
description: >-
  Agent-only output conventions for Firstmate ship and scout workers.
  Load before writing a report, a report summary, an explanation, a diagram, a review page, or an animation as a worker; the generated brief points here and carries a one-line reinforcement for ordinary status lines.
  Owns the plain-language writing profile, the notation map that picks a diagram notation by content shape, the output checklist, and the advisory prose lint.
user-invocable: false
metadata:
  internal: true
---

# output-conventions

This skill is the single owner of how a ship or scout worker writes and draws output for a reader.
Every rule adopts an existing framework and names it in parentheses, so you can look up the full rule.
Three items are custom because no framework states them: do not drop facts when shortening, draw every hop, and keep a page and its report in agreement.
The brief's status-line grammar, PR-URL rule, and report contract still decide what a line or report must contain; these conventions decide how it reads.

## Writing profile

Use this profile for status lines, reports, explanations, and summaries.
Do not use it for code, formatted commit messages, or quoted text.
"Plain" means the reader can find what they need, understand it, and use it (ISO 24495-1).

1. **Answer first.**
   The first sentence gives the state, the result, or the decision needed.
   A reader who stops there has the point (BLUF, Army AR 25-50).
2. **One point on top, grouped support below.**
   Each section and paragraph opens with its point.
   Keep one topic per paragraph.
   Use a list for three or more parallel items (Minto pyramid; Federal Plain Language Guidelines).
3. **Short, tight sentences.**
   Keep each sentence to 25 words or fewer.
   Keep subject, verb, and object close.
   Put a condition that decides whether the reader must act first ("If CI is green, merge").
   Keep link words ("because", "so", "but") when you split a sentence (Federal Plain Language Guidelines; Google developer style).
4. **Name the actor.**
   Use the active voice: "I", "firstmate", "CI", "the captain".
   Use the passive only when the actor is unknown (Federal Plain Language Guidelines; AR 25-50).
5. **One term per thing, and exact strings.**
   Keep the same term in the status line, the report, and the page.
   Copy names, IDs, paths, commands, error text, numbers, and URLs exactly (Federal Plain Language Guidelines; Microsoft Writing Style Guide).
6. **Remove ambiguity the reader cannot ask about.**
   Replace an ambiguous pronoun with its noun.
   Use no noun stack over three words.
   State the rule before its exceptions, in positive form.
   Use no idioms or filler (Google developer style; Microsoft Writing Style Guide; Federal Plain Language Guidelines).
7. **Say how you know.**
   Mark each claim as checked (with its evidence) or inferred.
   For a prediction, give one likelihood word from a fixed scale, such as likely or unlikely.
   In a repeated report, say what changed since the last one (ICD 203 standards 2, 3, and 7).
8. **Do not shorten by dropping facts.**
   Before you rewrite, list the facts.
   After you rewrite, check each one (custom).

You may use the reader's domain terms without defining them, contractions, "-ing" and perfect tenses, and "I", "you", and "we".
Help meant for a newcomer goes behind a link or a disclosure, not in the main text.
Replace only an ambiguous pronoun: repeating the name of the entity a sentence continues costs the reader (Gordon, Grosz & Gilliom 1993).

## Notation map

Pick the diagram notation by the shape of the content, not by habit (Moody's cognitive fit; the C4 FAQ).
C4 covers architecture only; its own FAQ excludes business processes, workflows, state machines, domain models, and data models.

| Content shape | Notation (framework) | Tool |
|---|---|---|
| Systems and who calls whom | C4 landscape, context, or container | Hand SVG on review pages; Structurizr for maintained architecture |
| What runs where | C4 deployment | Same |
| Messages and relays in order | UML sequence subset | Mermaid `sequenceDiagram`, or hand SVG with one lifeline per participant |
| Life of one thing | UML state machine subset | Mermaid `stateDiagram-v2` |
| Work that crosses people, with handoffs | Swimlanes with BPMN Descriptive semantics | Mermaid [`swimlane-beta`](https://mermaid.js.org/syntax/swimlanes) (11.16.0+), or hand SVG |
| Branching checks inside one actor | Flowchart (UML activity) | Mermaid `flowchart` |
| Entities and relations | ER, crow's foot | Mermaid `erDiagram` |
| Plan without committed dates | Now-Next-Later | Hand SVG or Claude Docs roadmap |
| Plan with real dates | Timeline or Gantt drawn to scale | Claude Docs `timeline`; Mermaid `gantt` |
| Open decision | IBIS map, or options x criteria table | Hand SVG or table |
| Decision made | ADR | Markdown |
| Options on two axes | 2x2 | Claude Docs 2x2; Mermaid `quadrantChart` |
| Amounts | Chart, not a diagram | Claude Docs charts; Vega-Lite in HTML |

Use each notation's small subset only:

- C4: landscape, context, container, and deployment views; skip component and code views, and use a UML sequence diagram instead of a C4 dynamic diagram (c4model.com).
  Do not use Mermaid's C4 syntax, which Mermaid marks experimental (Mermaid docs).
- UML sequence: lifelines, synchronous and asynchronous messages, `alt`, `opt`, `loop`, `par`, and notes (UML 2.5.1 section 17.8).
- UML state machine: states, initial and final states, and transitions labelled `trigger [guard]` (UML 2.5.1 section 14).
- Swimlanes: one lane per actor, solid arrows within a lane, dashed message arrows between lanes, and diamonds for gateways (BPMN 2.0.2 Descriptive conformance sub-class).

Apply the C4 notation checklist to every box-and-arrow diagram, whatever its notation: C4 says so itself.
Put the finding in the title and the diagram's type and scope in the subtitle (Claude Docs diagram guide; C4).

## Checklist

Run this before you hand over output; each item names its source.

**Text** (every status line, message, and report)

- [ ] The first sentence gives the state, the result, or the decision needed. *(BLUF)*
- [ ] Each section and paragraph opens with its point; parallel items are a list. *(Minto; Federal PLG)*
- [ ] No sentence is over 25 words.
  Conditions that decide action come first. *(Federal PLG; Google)*
- [ ] Active voice, actor named. *(Federal PLG; AR 25-50)*
- [ ] One term per thing across status line, report, and page.
  Names, IDs, paths, commands, numbers, and URLs are exact. *(Federal PLG; Microsoft)*
- [ ] No ambiguous pronoun, noun stack over three words, idiom, or exception before its rule. *(Google; Microsoft; Federal PLG)*
- [ ] Each claim is marked as checked or inferred.
  Predictions use a fixed likelihood word.
  Repeated reports say what changed. *(ICD 203 standards 2, 3, 7)*
- [ ] The fact list is checked after any shortening. *(custom)*

**Diagrams**

- [ ] The notation matches the content shape (notation map above). *(Moody cognitive fit; C4 FAQ)*
- [ ] It passes the C4 review checklist: title, type and scope, key; every element named and typed; every arrow labelled and one-way. *(C4)*
- [ ] The title states the finding.
  One sentence below gives the takeaway without re-describing the boxes. *(Claude Docs guide; Sweller redundancy effect)*
- [ ] Every hop is drawn: each relay is its own element or lifeline. *(custom)*
- [ ] Only what the evidence states.
  Unknowns are shown as questions.
  Time is to scale only when the dates are real. *(ICD 203 standard 9; Claude Docs; Now-Next-Later)*

**Pages**

- [ ] Overview first, at most two levels.
  Nothing most readers need is behind a details element, an accordion, or a tab. *(Shneiderman; NN/g; GOV.UK Design System)*
- [ ] Claims link to evidence.
  Charts show the key comparison by position or length. *(ICD 203; Cleveland & McGill)*
- [ ] The page and the report agree, and the full report is linked. *(custom)*
- [ ] Colour is never the only signal; the page reflows at phone width; motion can be paused. *(WCAG 2.2)*

**Animation**

- [ ] Motion only when change over time is the content.
  Every frame is a valid diagram. *(Tversky congruence; Heer & Robertson)*
- [ ] The viewer controls the pace; narration, not paragraphs of captions; a transcript and a reduced-motion fallback. *(Sweller transient information; Mayer; WCAG 2.2)*

## Advisory lint

`bin/fm-prose-lint.sh` checks a status line or report summary against this profile and only warns; its header owns usage, the lead-sentence check, and the Vale setup.
Its Vale config lives beside this skill in `assets/vale/`: three named rules from the Google and Microsoft packages plus two `Status` rules for the 25-word ceiling and a seed idiom list.
Vale is optional: without it the lint says so and runs the lead-sentence check alone.
The lead check counts words against rule 3's ceiling; rule 1's answer-first meaning needs a reviewer.
Expect some noise, such as passive-voice alerts inside quotes and examples; treat each alert as a prompt to reread, not a verdict.
Rules 5, 7, and 8 need a reviewer and a fact list, because no lint can check them.
