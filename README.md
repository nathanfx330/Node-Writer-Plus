# Node Writer

🌐 https://nathanfx330.github.io/blog/posts/node-writer/

![Node Writer Screenshot](https://nathanfx330.github.io/blog/posts/node-writer/nw-3.png)

**Node Writer** is a distraction-free, nonlinear writing environment built with Flutter.

Instead of forcing a manuscript into one long document, Node Writer lets you write in **Scene nodes**, arrange those scenes spatially, connect them into a graph, and compile the path into a linear manuscript when you need it.

The graph is not just an outline. It is the structure of the document.

Node Writer also integrates local **Piper text-to-speech** and **Ollama** tools without giving either system ownership of the writing. Voice playback follows the manuscript while you edit, and Ollama works through output nodes that inspect the compiled text at whatever point they are attached.

---

## Core Model

Node Writer deliberately keeps the graph simple.

### Scene

The **Scene** is the universal writing node.

A Scene contains the actual manuscript text. The name is customizable in **Settings → Formatting**, so the same node can be presented as a Scene, Paragraph, Passage, Section, Beat, Card, or another preferred writing unit.

Scene nodes provide:

- Full writing editor
- Line numbers
- **bold** and *italic* formatting
- Search
- Follow-along TTS highlighting
- Double-click to read from a sentence
- Authorial protection for selected text
- Visual graph connections

### Merge

A **Merge** node combines parallel branches into a single ordered flow.

It is useful when several writing paths need to converge before continuing into another Scene or Output.

### Final Output

**FINAL OUTPUT** is a terminal compilation node.

It shows the complete manuscript feeding that point in the graph and provides document-level tools such as Piper voice playback and Ollama spell checking.

### Ollama Output

An **OLLAMA OUTPUT** is also terminal.

It does **not** contain manuscript prose and it does not become part of the writing chain.

Attach one anywhere in the graph and it receives the manuscript compiled **up to that exact point**:

```text
Scene 1 → Scene 2 → Scene 3 → FINAL OUTPUT
                    │
                    └────────→ OLLAMA OUTPUT
```

The Ollama Output can then analyze, critique, summarize, question, or otherwise work with that snapshot without rewriting the Scene nodes.

This makes it possible to place several Ollama outputs at different points in a project for different editorial questions.

---

## Features

### Infinite Canvas

Pan and zoom freely to organize writing in open space.

### Visual Document Graph

Connect Scene nodes with Bézier curves and use the graph itself to define manuscript flow.

Disconnected material can remain on the canvas without appearing in a compiled output.

### Ordered Merges

Merge multiple branches into one intentional linear sequence.

### Live Compilation

Selecting an Output node shows the manuscript compiled from the writing feeding that point.

### Compiled Output Shape

**Settings → Formatting** controls what copied and exported text looks like:

- Node titles as ALL CAPS headings, on or off
- A horizontal rule between nodes, on or off

Ollama always receives headings regardless of this setting, because a model reading the document benefits from seeing its structure, while a manuscript export usually should not carry editor scaffolding.

### Custom Writing Terminology

Rename the universal writing node to fit the project:

- Scene
- Paragraph
- Passage
- Section
- Beat
- Card
- Header

### Rich Text Lite

Use lightweight Markdown-style emphasis while keeping the editor clean:

- `**bold**`
- `*italic*`

### Line Numbers

Scene editors include stable logical line numbers in the gutter.

These refer to actual newline-delimited manuscript lines rather than visual wrapping, so references remain stable when the panel is resized.

### Find in Scene

Use the magnifying-glass control or `Ctrl+F` to search the current Scene.

Matches are highlighted directly in the editor and can be stepped through without moving search keystrokes into the manuscript.

---

## Voice: Piper TTS

Scene writing has a **WRITE | VOICE** workflow.

Piper runs locally and can read either a Scene or compiled manuscript without sending writing to an online speech service.

Voice features include:

- Sentence-by-sentence playback
- Follow-along highlighting
- Caret and editor scrolling that follow the spoken sentence
- Double-click a sentence to begin reading there
- Stop playback directly from the editor
- Voice-model selection
- Adjustable speech speed
- Optional speaker ID
- CUDA/GPU provider test
- WAV rendering
- Optional SRT subtitle generation
- Prefetched sentence generation for smoother playback

When compiled playback crosses into another Scene, Node Writer can follow the active Scene in the graph.

### Piper Runtime Layout

Piper is optional and is not bundled in the repository.

During development, place the Piper runtime and voice models beside the Flutter project:

```text
node-writer/
├── lib/
├── linux/
├── pubspec.yaml
│
├── piper/
│   ├── piper
│   └── ...Piper runtime libraries
│
└── model/
    ├── voice-name/
    │   ├── voice.onnx
    │   └── voice.onnx.json
    └── ...
```

On Windows, the executable is expected as:

```text
piper/piper.exe
```

For a packaged application, Node Writer also checks for `piper/` and `model/` beside the application executable.

---

## Ollama

Node Writer can use a locally running Ollama server as an editorial processor.

Ollama settings are global and live in:

**Settings → Ollama**

Configure:

- Ollama host
- Default model
- Shared system prompt

The default local Ollama host is:

```text
http://localhost:11434
```

Node Writer discovers locally available models from the Ollama server.

### Ollama Outputs

An Ollama Output receives the exact compiled manuscript feeding its position in the graph.

Its side panel provides:

- The compiled input
- A node-specific **Ask**
- Run control
- Ollama's returned result

The result is editorial output, not manuscript text. Nothing is silently inserted into Scene nodes.

Example asks:

```text
Where does this argument become repetitive?
```

```text
Challenge the logic of this section without rewriting it.
```

```text
List the claims here that need stronger evidence.
```

```text
Give me three ways this transition could be clearer.
```

---

## Authorial Constraints

Node Writer is designed around a simple principle:

> AI assistance does not imply AI authorship permission.

Select text inside a Scene and right-click to protect it from downstream Ollama operations.

### Protect Exact Wording

**Protect from Ollama — exact wording** marks text whose characters belong entirely to the author.

Before generation, Node Writer replaces each protected passage with an opaque token. After generation it restores the original characters. Ollama never gets an opportunity to retype the protected words, because it never receives them in the editable body of the document.

Enforcement differs by operation, because the two operations are asking for different things:

- **Manuscript-returning operations** such as spell check must return a complete document, so every token has to come back exactly once. A missing, duplicated, or invented token means the passage changed, and the result is **rejected** rather than restored.
- **Analysis operations**, such as an Ollama Output asking a question, are not returning the manuscript. A token that does not appear is normal. Duplicated or invented tokens are reported as a warning alongside the result.

### Edits release locks

An exact lock is a claim about specific characters. If an edit overwrites part of a protected span, Node Writer releases that lock and says so, rather than silently re-anchoring an authorship guarantee onto whatever replaced it. Editing before or after a lock moves it normally.

### Protect Meaning / Claim

**Protect meaning / claim** tells Ollama that the proposition itself is an authorial constraint.

Ollama may analyze or criticize the claim, but editorial operations are instructed not to:

- Reverse it
- Weaken it
- Strengthen it
- Change its scope
- Change its certainty
- Reinterpret its intended meaning

Meaning protection is semantic rather than mechanically absolute, so manuscript-returning operations can perform a second verification pass and report a protected claim as:

- `PRESERVED`
- `CHANGED`
- `UNCERTAIN`

Authorial constraints are saved with the Node Writer project and travel downstream with the compiled manuscript.

---

## Ollama Spell Check

FINAL OUTPUT includes an Ollama-powered spell-check workflow.

The copy-edit instruction is intentionally narrow. It asks Ollama to correct:

- Spelling
- Grammar
- Punctuation
- Capitalization
- Obvious typographical errors

while preserving:

- Wording
- Voice
- Meaning
- Paragraph structure
- Headings
- Markdown

The corrected manuscript opens for review rather than silently overwriting Scene nodes.

Exact author locks are mechanically enforced during this process, and protected meaning claims can be checked after generation.

---

## Saving

Node Writer writes through a temporary file and renames it into place, so an interrupted or failed write cannot truncate an existing project. The previous version of the file is kept alongside it as `projectname.nw.bak`.

Save results are reported in the interface. A failed save is never silent.

A dot beside the project name in the title bar means there are changes that are not on disk. **New** and **Open** will offer to save before discarding them.

---

## Development

### Tests

```bash
flutter test
```

The suite covers the parts where a silent regression would be expensive:

- Sentence chunking, asserting that chunk offsets tile the document exactly. Follow-along highlighting depends on that invariant.
- Authorial constraint remapping across insert, delete, and overwrite edits, including the release-on-overwrite rule.
- Graph compilation order, merge port ordering, and termination on a cyclic project file.
- Harness token substitution, restoration, and every rejection path.

### Static analysis

```bash
flutter analyze
```

`analysis_options.yaml` treats a dropped `Future` and an unguarded `BuildContext` across an `await` as errors, since in this codebase both mean a lost save or an orphaned process.

---

## Getting Started

### Prerequisites

Install Flutter:

https://flutter.dev/docs/get-started/install

Verify the installation:

```bash
flutter doctor
```

Piper and Ollama are optional. Node Writer's core graph editor works without either one.

For Ollama features, install Ollama separately, start the local server, and make sure at least one model is available.

---

### Clone the Repository

```bash
git clone https://github.com/nathanfx330/node-writer.git
cd node-writer
```

### Fetch Dependencies

```bash
flutter pub get
```

### Run

```bash
flutter run
```

For Linux specifically:

```bash
flutter run -d linux
```

---

## Clean Rebuild

When native dependencies or Flutter plugins have changed, a clean rebuild can help:

```bash
flutter clean
rm -rf .dart_tool build
flutter pub get
flutter build linux --release
```

The Linux release bundle is generated under:

```text
build/linux/x64/release/bundle/
```

---

## Build Release Versions

### Windows

```bash
flutter build windows --release
```

### Linux

```bash
flutter build linux --release
```

### macOS

```bash
flutter build macos --release
```

---

## Philosophy

Node Writer separates three things that conventional word processors tend to collapse together:

```text
WRITING
    ↓
STRUCTURE
    ↓
OUTPUT / PROCESSING
```

**Scene nodes** are where the author writes.

**The graph** determines how that writing relates and compiles.

**Output nodes** observe the resulting manuscript without becoming manuscript themselves.

Piper can perform the writing aloud.

Ollama can inspect it.

Neither one needs to become the author.

---

## License

MIT License

Copyright (c) 2026 Nathaniel Westveer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
