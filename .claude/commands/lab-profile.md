# Lab Voice Profile Builder

Build a writing voice profile by interviewing the user directly. The goal is to capture their natural, unfiltered language -- not to analyze or infer from existing content. Save the profile locally so it can inform future article generation.

## Instructions

Walk the user through the following interview in order. Ask one section at a time. Do not rush or batch questions -- give the user space to respond naturally. Their exact words and phrasing in responses are the raw material for the profile.

---

### Step 1: Warmup -- get them talking naturally

Ask the user to briefly describe, in their own words, what their blog/lab is about and who it is for. Do not suggest answers. Let them write freely. Note the vocabulary, sentence rhythm, and energy level in their response.

---

### Step 2: Topic deep dive -- capture natural language under pressure

Pick two topics that are likely to be covered in their writing (infer from the warmup or ask them to name two subjects they write about). For each topic, ask them to explain it as if talking to a peer who is technically competent but unfamiliar with the specific context. Tell them to write at least three sentences and not to edit themselves.

Note:
- Do they use analogies?
- Do they front-load context or dive in?
- Do they use hedging language or state things directly?
- Do they use humor or irony?

---

### Step 3: Temperament and personality settings

Present the user with the following axes and ask them to place themselves on each one. Accept a number 1-5 or a description -- whatever feels natural to them.

| Axis | 1 | 5 |
|---|---|---|
| Formality | Conversational, loose | Precise, structured |
| Humor | Serious throughout | Snarky or irreverent |
| Confidence | Hedged, exploratory | Direct, declarative |
| Density | Short and punchy | Long, thorough explanations |
| Warmth | Clinical, detached | Personal, first-person |

After they respond, ask one follow-up: "Is there a temperament or personality trait you want the writing to have that isn't captured above?" Accept free text.

---

### Step 4: Things they hate in writing

Ask the user: "What are three things you commonly see in blog posts or technical writing that you hate or want to avoid in your own writing?" Do not suggest examples first. After they answer, note any patterns (e.g., aversion to filler phrases, listicles, passive voice, corporate-speak, false enthusiasm).

---

### Step 5: Signature phrase check

Ask the user to write two or three sentences -- on any topic, real or made-up -- the way they would actually write them in a post. No editing, no second-guessing. This is to capture their natural sentence construction and punctuation habits.

---

### Step 6: Synthesize and confirm

After collecting all responses, synthesize the profile. Draft the profile in the format below and show it to the user before saving. Ask them: "Does this capture how you want to sound? Anything to add or change?" Revise based on their feedback, then save.

---

## Profile file format

Write the finalized profile to `.claude/voice-profile.md`:

```markdown
---
generated: <ISO date>
---

# Writing Voice Profile

## Temperament settings
<Summarize the axis scores with brief notes on what they mean in practice>

## Natural language patterns
<What you observed from their warmup and topic deep dive responses -- rhythm, vocabulary, structure. Quote their actual phrases as examples.>

## Things this author avoids
<Direct list from Step 4, with any inferred implications>

## Signature construction
<Observations from Step 5 -- sentence length, punctuation style, use of conjunctions, clause nesting, etc.>

## Writing directive
<3-5 sentence synthesis written as an active instruction. Example: "Write in first person. Use short declarative sentences for conclusions, longer compound sentences to build context. Avoid hedging. Dry humor is welcome but never forced. No em dashes.">
```

---

## Adaptation note for other projects

To use this skill in a different project:
- The interview questions are generic and work for any prose author.
- The temperament axes can be extended with domain-specific axes (e.g., "Technical depth: surface-level vs. implementation detail").
- Change the output path (currently `.claude/voice-profile.md`) to wherever you want the profile stored -- keep it gitignored.
