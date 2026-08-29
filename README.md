# Node Writer Plus

**Node Writer Plus** is a nonlinear desktop writing environment built with Flutter.

Instead of treating a manuscript as one long document, Node Writer Plus breaks writing into connected units arranged on a visual canvas.

Scenes contain the writing.

Connections define structure.

Merge nodes determine how independent sections come together.

Final Output compiles the graph into a linear manuscript.

EchoText based Piper tools can read that manuscript aloud locally.

Node Leaf inspired local model tools can examine it through Ollama.

The basic model is:

```text
WRITE
  ↓
STRUCTURE
  ↓
COMPILE
  ↓
LISTEN / REVIEW / PROCESS
```

The graph is not simply an outline of the document.

**The graph is the document structure.**

## Where Node Writer Plus Comes From

Node Writer Plus brings together ideas and working systems developed across three projects.

### Node Writer

Node Writer provides the foundation.

It introduced the visual writing model in which manuscript text lives inside writing nodes and the relationships between those nodes determine the structure of the finished document.

Instead of outlining a manuscript in one place and writing it somewhere else, the structure and the writing occupy the same workspace.

### EchoText

EchoText provides the foundation of the Voice system.

EchoText was built around local Piper neural voices and developed the playback and rendering workflow that is now integrated into Node Writer Plus.

That includes:

* Local ONNX voices
* Sentence based playback
* Playback from a selected location
* Follow along highlighting
* Adjustable speech speed
* Multi speaker model support
* CUDA acceleration
* WAV rendering
* SRT subtitle generation
* Long form rendering
* Sentence timing and audio cleanup

In Node Writer Plus, those tools are no longer attached to one large text document.

They can operate on an individual Scene or on a complete manuscript assembled from the graph.

### Node Leaf

Node Leaf contributes the local model processing approach.

Models are treated as tools attached to structured information rather than as replacements for the underlying material.

Node Writer Plus applies that idea to writing.

Ollama does not become the document.

Instead, an Ollama Output receives the manuscript that reaches a particular point in the graph and performs a defined task against that compilation.

This makes local model processing part of the document architecture rather than a chatbot sitting beside the editor.

### The Convergence

Node Writer Plus is where those three systems meet.

```text
NODE WRITER
Visual writing and manuscript structure
        ↓
NODE WRITER PLUS
        ↑
ECHOTEXT                    NODE LEAF
Local voice                 Local model processing
```

The result is not simply Node Writer with voice and model buttons added to it.

The writing remains the source of truth.

The graph controls structure.

EchoText's voice system can perform the writing aloud.

The Node Leaf inspired processing layer can examine the writing.

Neither system needs to take ownership of the manuscript.

## The Node Model

Node Writer Plus deliberately uses a small set of node types.

### Scene

A Scene is the universal writing node.

It contains manuscript text.

The name of the writing unit can be changed in Settings, allowing the same node to represent different kinds of work.

Available names currently include:

* Scene
* Passage
* Paragraph
* Section
* Beat
* Card
* Header

Scene nodes provide the main writing environment, including:

* Line numbers
* Bold formatting
* Italic formatting
* Text alignment
* Multiple editor font styles
* Find within the current Scene
* Piper playback from the editor
* Follow along speech highlighting
* Authorial protection for selected text
* Visual graph connections

The Scene is where authorship happens.

### Merge

A Merge node combines separate writing paths into one ordered flow.

Each Merge provides three ordered inputs.

The left input is compiled first.

The center input follows.

The right input is compiled last.

```text
SECTION A ───╮
SECTION B ───┼→ MERGE → NEXT SECTION
SECTION C ───╯
```

This allows sections to be developed independently on the canvas and deliberately assembled when their final relationship becomes clear.

Merge order is structural.

The physical organization of the canvas therefore has a direct relationship to the resulting manuscript.

### Final Output

FINAL OUTPUT is the manuscript sink.

It compiles every Scene that reaches it into a linear document according to the graph.

From Final Output you can:

* Read the compiled manuscript
* Jump from the preview back to individual Scenes
* Copy the manuscript
* Export the manuscript as text or Markdown
* Listen to the complete manuscript with Piper
* Render the manuscript to WAV
* Generate optional SRT subtitles
* Run an Ollama assisted spell check

Final Output does not contain manuscript prose of its own.

It represents the document produced by the graph.

### Ollama Output

OLLAMA OUTPUT is a terminal processing node.

Connect one at any point in the graph and it receives the manuscript compiled up to that exact point.

```text
SCENE 1 → SCENE 2 → SCENE 3 → FINAL OUTPUT
                     │
                     └────────→ OLLAMA OUTPUT
```

An Ollama Output can then be given its own question or instruction.

For example:

```text
Where does this argument become repetitive?
```

```text
Identify claims that need stronger evidence.
```

```text
Critique the transition between these sections.
```

```text
What questions would a skeptical reader ask here?
```

```text
Summarize the argument established up to this point.
```

The returned result is editorial output.

It does not silently replace or rewrite the Scene nodes that supplied the manuscript.

Several Ollama Outputs can therefore exist at different points in the same project, each examining a different manuscript state or answering a different editorial question.

## Visual Writing

Node Writer Plus uses a large spatial canvas for arranging manuscript pieces.

Writing can be moved visually, connected, disconnected, branched, reorganized, and merged.

Unused material can remain nearby without becoming part of a compiled manuscript.

Only writing that reaches the selected Output is compiled.

That means material does not need to be deleted simply because it is not currently part of the document.

It can remain on the canvas as an alternate passage, discarded idea, possible branch, research note, or section waiting to be placed.

The canvas and the editor remain connected.

Selecting a Scene opens its writing environment.

Selecting Final Output opens the compiled manuscript.

Selecting an Ollama Output shows the manuscript feeding that node and provides its model workspace.

## Writing Environment

The right side panel serves as the primary writing surface.

It can be resized for editing and expanded into a wider writing layout while preserving access to the visual canvas.

Scene editing currently includes:

* Stable logical line numbers
* Bold and italic Markdown style formatting
* Left alignment
* Center alignment
* Right alignment
* Modern display style
* Classic display style
* Typewriter display style
* Search with match navigation
* Direct Piper playback
* Double click playback from the current sentence
* Authorial protection controls

Search operates inside the selected Scene.

Match navigation keeps keyboard focus inside the search field so search text does not accidentally enter the manuscript.

## Manuscript Compilation

Node Writer Plus compiles the graph toward a selected Output.

The compiler walks the upstream graph, resolves Merge ordering, gathers Scene content, and produces a linear manuscript.

Writing that does not reach the target is not included.

Compilation also preserves information about protected authorial spans so those protections continue to exist after multiple Scenes become one document.

### Output Formatting

Settings can control the author facing shape of compiled text.

You can currently choose whether exported text includes:

* Scene titles as headings
* Horizontal rules between Scenes

Ollama receives structural headings regardless of the author facing export setting.

This allows a model to understand where sections begin and end without forcing those same structural markers into a finished manuscript export.

The manuscript intended for the author and the manuscript intended for local model processing can therefore use different presentation rules while coming from the same graph.

## Voice

The Voice workspace is based on the Piper system developed in EchoText.

Piper runs locally.

The manuscript does not need to be sent to an online speech service.

Voice can operate on either:

* The selected Scene
* The compiled manuscript

Selecting Final Output automatically makes the complete manuscript feeding that Output the Voice source.

## Follow Along Playback

Speech is generated in sentence sized chunks.

As Piper moves through the manuscript, Node Writer Plus tracks the passage currently being spoken.

During compiled playback it can follow the manuscript across Scene boundaries.

When playback reaches another Scene, the application can:

* Select that Scene
* Center it on the canvas
* Highlight the spoken passage
* Move the editor caret with playback
* Scroll the editor toward the active sentence

Double clicking inside a Scene can begin playback from the sentence at that location.

Playback can also be stopped directly from the writing interface.

## Voice Controls

The current Voice implementation includes:

* Piper voice selection
* Custom ONNX voice selection
* Adjustable speech speed
* Optional speaker ID
* Optional CUDA acceleration
* CUDA capability testing
* Sentence prefetching
* Selected Scene playback
* Compiled manuscript playback
* Follow along highlighting
* WAV rendering
* Optional SRT subtitle generation
* Render progress
* Estimated render completion time

The Voice system retains a substantial amount of the long form rendering work developed in EchoText.

## Piper Setup

Piper itself and the voice models are not included with Node Writer Plus.

The repository currently contains a placeholder `piper` directory, but you need to supply the actual Piper runtime.

**For the current development version, the entire Piper runtime needs to be placed directly in the root of the Node Writer Plus project.**

The working development layout is:

```text
Node-Writer-Plus/
│
├── lib/
├── linux/
├── windows/
├── macos/
├── pubspec.yaml
│
├── piper/
│   ├── piper
│   ├── espeak-ng-data/
│   └── Piper runtime libraries
│
└── model/
    ├── Voice A/
    │   ├── voice.onnx
    │   └── voice.onnx.json
    │
    └── Voice B/
        ├── another_voice.onnx
        └── another_voice.onnx.json
```

On Linux, Node Writer Plus currently expects the executable at:

```text
Node-Writer-Plus/piper/piper
```

On Windows:

```text
Node-Writer-Plus/piper/piper.exe
```

Voice models belong inside folders under:

```text
Node-Writer-Plus/model/
```

Node Writer Plus scans those folders for ONNX voice models.

### Linux Permissions

The application attempts to make the Piper executable runnable automatically.

If necessary, this can also be done manually from the project root:

```bash
chmod +x piper/piper
```

### Current Piper Status

The Piper integration is functional on the primary Linux development machine using the directory structure above.

It still needs portability and packaging work.

The current Node Writer Plus build configuration should not yet be assumed to bundle the Piper runtime and voice models automatically into every release build.

That part of the EchoText packaging system still needs to be properly integrated and tested here.

For now, when running Node Writer Plus from source, keep the complete Piper runtime in the project root exactly as shown above.

**It works, but it still needs love.**

## Ollama

Ollama support is optional.

Node Writer Plus uses Ollama as a local manuscript processing system.

By default the application expects a local Ollama server at:

```text
http://localhost:11434
```

The Ollama settings panel allows you to configure:

* Ollama host
* Default model
* Shared system prompt

Available models are discovered from the configured Ollama server.

Because the host is configurable, Ollama can also run somewhere else on a local network.

## Ollama Outputs

An Ollama Output receives the exact manuscript compilation feeding its point in the graph.

Its workspace contains:

* The compiled manuscript input
* A node specific Ask
* A Run control
* The returned result

The Ask belongs to that Ollama Output and is saved with the project.

The generated result is stored separately from the authored manuscript.

This allows local models to act as readers, critics, researchers, proofreaders, or analytical tools without silently modifying the underlying Scenes.

## Authorial Constraints

Node Writer Plus treats model assistance and model authorship as different things.

Selected text inside a Scene can be protected before it reaches Ollama.

There are two kinds of authorial protection.

### Exact Wording

Exact protection means the characters themselves belong to the author and must not be rewritten.

Before protected manuscript text passes through an editable Ollama workflow, the protected passage is replaced with an opaque token.

The model works around that token rather than receiving permission to rewrite the protected characters.

When a complete document operation returns, Node Writer Plus validates the tokens before restoring the original wording.

For manuscript returning operations, a protected token must return exactly once.

If a token is:

* Missing
* Duplicated
* Altered
* Invented

the result is rejected rather than silently repaired.

Exact wording protection is therefore not only an instruction inside a prompt.

It also has a mechanical enforcement layer.

### Meaning / Claim

Meaning protection applies to the proposition rather than the exact wording.

The model may analyze or criticize a protected claim when explicitly asked to do so.

Editorial operations are instructed not to change its:

* Direction
* Scope
* Certainty
* Emphasis
* Intended meaning

For manuscript editing operations, Node Writer Plus can perform a second semantic verification pass.

Protected claims can be reported as:

```text
PRESERVED
CHANGED
UNCERTAIN
```

Exact protection and meaning protection therefore serve different purposes.

One protects characters.

The other protects the author's proposition.

## Editing Protected Text

An authorial lock belongs to the material that was explicitly protected.

If the author later edits directly through a protected span, Node Writer Plus releases that protection rather than silently moving an authorship guarantee onto replacement text.

Editing before or after the protected passage moves its location normally.

When an edit causes a protection to be released, the application reports that release to the author.

## Ollama Spell Check

Final Output includes an Ollama assisted proofreading workflow.

The instruction is intentionally narrow.

The model is asked to correct:

* Spelling
* Grammar
* Punctuation
* Capitalization
* Obvious typographical errors

while preserving:

* Wording
* Voice
* Meaning
* Paragraph structure
* Headings
* Markdown

The corrected manuscript opens in a review window.

The source Scenes remain untouched.

Nothing is silently written back into the manuscript.

If exact authorial locks exist, they are validated before the corrected result is accepted for review.

If meaning locks exist, they can receive a second preservation check.

The author remains responsible for deciding whether to use the returned correction.

## Export

Compiled manuscripts can be copied directly from Final Output.

They can also be exported as:

```text
.txt
.md
```

Voice rendering can produce:

```text
.wav
```

and optionally:

```text
.srt
```

The SRT workflow uses the same sentence based rendering path used by Voice so subtitle timing follows the generated speech.

## Project Files

Node Writer Plus projects use the `.nw` format.

A project stores information including:

* Scene text
* Node titles
* Node positions
* Graph connections
* Merge structure
* Writing unit terminology
* Formatting preferences
* Ollama asks
* Ollama results
* Authorial constraints
* Compiled output preferences

## Saving and Manuscript Safety

Writing software should never treat a failed save as a minor error.

Node Writer Plus therefore avoids directly truncating the existing project before a replacement is ready.

A save is first written to a temporary file.

When an existing project is replaced, the previous copy is preserved alongside it as:

```text
project.nw.bak
```

The interface also tracks whether the current project contains changes that have not reached disk.

An unsaved indicator appears beside the project name.

Starting a new project or opening another project while unsaved work exists produces a warning.

The author can:

* Cancel
* Save first
* Explicitly discard the changes

Save failures are reported through the interface.

They are not intentionally allowed to disappear silently into a debug log.

## Undo

Node Writer Plus maintains an undo history for graph and writing operations.

Continuous typing and similar repeated actions are grouped so normal writing does not generate an unusable undo entry for every character.

The current project state supports up to 100 stored undo snapshots.

## Getting Started

### Requirements

Node Writer Plus is built with Flutter and currently targets desktop use.

The current project uses Dart:

```text
^3.11.3
```

Install Flutter and verify the environment with:

```bash
flutter doctor
```

Piper and Ollama are optional.

The core writing graph works without either one.

### Clone Node Writer Plus

```bash
git clone https://github.com/nathanfx330/Node-Writer-Plus.git
cd Node-Writer-Plus
```

### Install Flutter Dependencies

```bash
flutter pub get
```

### Run on Linux

```bash
flutter run -d linux
```

Or allow Flutter to choose an available target:

```bash
flutter run
```

## Building

### Linux

```bash
flutter build linux
```

For a release build:

```bash
flutter build linux --release
```

The Linux release bundle is normally generated under:

```text
build/linux/x64/release/bundle/
```

### Windows

```bash
flutter build windows
```

For a release build:

```bash
flutter build windows --release
```

### macOS

```bash
flutter build macos
```

For a release build:

```bash
flutter build macos --release
```

Linux is currently the primary development environment for Node Writer Plus.

The repository includes Windows and macOS Flutter targets, but the current Plus codebase should not yet be treated as equally verified on every platform.

Piper packaging in particular still requires additional platform work.

## Development Status

Node Writer Plus is active development software.

The main writing, graph compilation, Piper integration, Ollama Output system, authorial constraints, and compiled export workflows are implemented.

Some infrastructure in the repository is ahead of what is currently wired into the application.

For example, work exists toward broader session recovery and automatic recovery snapshots, but that system should not yet be considered part of the active user facing feature set until it is fully connected and tested.

Platform packaging also needs further work, especially around distributing Piper and voice models cleanly with release builds.

## Current Testing Note

The current repository does not yet have a mature automated test suite representing the full Node Writer Plus feature set.

Testing infrastructure and regression coverage are areas that still need development.

The existing application behavior has primarily been developed and exercised interactively on the primary development machine.

## Why Plus Exists

The original Node Writer established the visual writing model.

Node Writer Plus extends that idea into a broader writing environment.

The important separation is:

```text
AUTHOR
  ↓
SCENES
  ↓
GRAPH
  ↓
COMPILED MANUSCRIPT
  ↓
OUTPUT TOOLS
```

Scenes contain authored text.

The graph defines how that text becomes a document.

Final Output compiles it.

EchoText's Piper system can perform it aloud.

Ollama can inspect it.

Authorial constraints define what a model is allowed to alter.

These systems are intentionally separate.

A voice engine does not need to become an editor.

A local model does not need to become an author.

A graph does not need to replace prose.

Node Writer Plus is built around keeping those responsibilities distinct while still allowing them to work together.

The goal is not simply to build a word processor with local AI attached to the side.

The goal is to build a writing environment where **authorship, structure, voice, and machine assistance remain separate enough that the author decides exactly how they interact.**

## License

MIT License

Copyright (c) 2026 Nathaniel Westveer

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

