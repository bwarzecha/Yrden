# Design: Agent Skills

## Problem

An agent without skills is a generalist. It can follow instructions, use tools, and produce structured output — but it has no specialized knowledge. When a user asks it to "create a presentation" or "review this code for security issues," it has to improvise from its training data. This works sometimes. It fails when the task requires specific procedures, company conventions, or domain expertise that the model doesn't have.

The Agent Skills standard (agentskills.io) solves this by letting agents load packaged instructions on demand. A "pdf-processing" skill teaches the agent how to extract tables from PDFs. A "code-review" skill teaches it your team's review checklist. Skills are just folders with a `SKILL.md` file — portable, versionable, and sharable across any compatible agent.

The standard has been adopted by Claude Code, Cursor, VS Code, OpenAI Codex, Gemini CLI, Goose, Amp, Roo Code, GitHub, and 20+ other agent products. No Swift library implements it.

### Why this matters for Yrden

1. **Ecosystem access** — Thousands of existing skills (Anthropic's catalog alone has 65K GitHub stars) become instantly usable
2. **Differentiation** — First Swift AI library with skills support
3. **Composability** — Skills complement tools. Tools give agents *capabilities* (call APIs, read files). Skills give agents *expertise* (how to use those capabilities effectively)
4. **User demand** — Every major coding agent now supports skills. Users building agents with Yrden will expect it

### What a skill looks like

```
code-review/
├── SKILL.md              # Required: metadata + instructions
├── scripts/
│   └── lint-check.sh     # Optional: executable code
├── references/
│   └── CHECKLIST.md      # Optional: detailed docs loaded on demand
└── assets/
    └── severity-matrix.json  # Optional: static resources
```

The `SKILL.md`:
```yaml
---
name: code-review
description: Review code for bugs, security vulnerabilities, and style issues. Use when the user asks for a code review or PR review.
---

# Code Review

## Steps
1. Read the changed files
2. Check against the security checklist in references/CHECKLIST.md
3. Run the linting script: scripts/lint-check.sh
4. Provide findings grouped by severity
...
```

---

## Research: The Agent Skills Standard

Source: https://agentskills.io/specification (v1, published December 2025)

### Specification Summary

The standard is deliberately minimal — the entire spec fits in a few pages.

**Directory structure:**
```
skill-name/
├── SKILL.md          # Required
├── scripts/          # Optional: executable code
├── references/       # Optional: additional docs
└── assets/           # Optional: templates, data files
```

**SKILL.md format:** YAML frontmatter + Markdown body.

**Required frontmatter fields:**

| Field | Constraints |
|-------|------------|
| `name` | 1-64 chars, lowercase alphanumeric + hyphens, no leading/trailing/consecutive hyphens, must match parent directory name |
| `description` | 1-1024 chars, describes what the skill does AND when to use it |

**Optional frontmatter fields:**

| Field | Purpose |
|-------|---------|
| `license` | License name or reference to bundled file |
| `compatibility` | Max 500 chars, environment requirements (e.g., "Requires git, docker") |
| `metadata` | Arbitrary key-value map (author, version, etc.) |
| `allowed-tools` | Space-delimited list of pre-approved tools (experimental) |

**Markdown body:** Free-form instructions. No format restrictions. Recommended sections: step-by-step instructions, input/output examples, edge cases.

**File references:** Relative paths from skill root. Keep one level deep — avoid deeply nested reference chains.

**Size guidance:** Keep SKILL.md under 500 lines / ~5000 tokens. Move detailed reference material to `references/`.

### Progressive Disclosure Model

The standard defines three tiers for efficient context management:

| Tier | What loads | When | Token cost |
|------|-----------|------|------------|
| **1. Metadata** | `name` + `description` only | Agent startup, all skills | ~50-100 tokens each |
| **2. Instructions** | Full SKILL.md body | When skill matches task | <5000 tokens recommended |
| **3. Resources** | Files in scripts/, references/, assets/ | On demand during execution | Varies |

This is critical for agents with limited context windows. Loading all skills fully at startup would consume thousands of tokens of system prompt. Progressive disclosure means 20 skills add ~2000 tokens of metadata at startup, and only the activated skill's full instructions enter context.

### Validation

The `skills-ref` reference library (Python, Apache 2.0) provides:
- `skills-ref validate <path>` — validates SKILL.md frontmatter and naming conventions
- `skills-ref to-prompt <path>...` — generates XML for system prompt injection

---

## Research: How Major Agents Implement Skills

### Claude Code (most complete implementation)

Claude Code extends the base spec significantly:

**Discovery locations (precedence order):**
1. Enterprise managed settings
2. Personal: `~/.claude/skills/<skill-name>/SKILL.md`
3. Project: `.claude/skills/<skill-name>/SKILL.md`
4. Plugin: `<plugin>/skills/<skill-name>/SKILL.md`
5. Monorepo: auto-discovers nested `.claude/skills/` in subdirectories

**Extended frontmatter (beyond the standard):**
- `disable-model-invocation` — prevents auto-loading (manual `/name` invocation only)
- `user-invocable: false` — hides from `/` menu (background knowledge only)
- `allowed-tools` — restricts which tools Claude can use when skill is active
- `model` — specify which model to use
- `context: fork` — run in isolated subagent context
- `agent` — which subagent type to use
- `hooks` — lifecycle hooks scoped to the skill
- `argument-hint` — autocomplete hints

**String substitutions:** `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N`, `${CLAUDE_SESSION_ID}`

**Dynamic context injection:** `` !`command` `` syntax runs shell commands before skill content is sent, inserting stdout into the skill prompt.

**Activation mechanism:** Skills inject two user messages — one with metadata (visible as status indicator) and one with the full prompt (hidden from UI). This is prompt expansion, not function calling.

**Token budget:** Skill descriptions loaded at 2% of context window, fallback 16,000 characters.

### OpenAI Codex

**Discovery locations (precedence order):**
1. REPO local: `.agents/skills/`
2. REPO parent: `../.agents/skills/`
3. REPO root: `$REPO_ROOT/.agents/skills/`
4. USER: `$HOME/.agents/skills/`
5. ADMIN: `/etc/codex/skills/`
6. SYSTEM: bundled with Codex

**Extensions:** `agents/openai.yaml` for UI configuration (display name, icons, brand color, default prompt).

**Built-in meta-skills:** `$skill-creator` for creating skills, `$skill-installer` for installing from remote.

**Invocation:** `$skill-name` syntax (vs Claude's `/skill-name`).

### Cursor

Cursor adopted the standard with minimal extensions. Skills are stored in `.cursor/skills/`. Discovery is project-scoped. No extended frontmatter documented.

### LangChain

LangChain implements skills as a `load_skill` meta-tool:
```python
@tool
def load_skill(skill_name: str) -> str:
    """Load a specialized skill prompt"""
    # Returns SKILL.md body content
```

This is the tool-based integration approach from the spec. The agent decides when to call `load_skill`, and the returned instructions enter the conversation as a tool result.

LangChain also supports hierarchical skill organization — a "data_science" skill can contain "pandas_expert", "visualization", "statistical_analysis" sub-skills.

### Integration Approach Comparison

The spec defines two integration approaches:

| Approach | How it works | Best for | Used by |
|----------|-------------|----------|---------|
| **Filesystem-based** | Agent has shell access, reads `SKILL.md` via file operations | Agents with tool access | Claude Code, Codex |
| **Tool-based** | Agent calls `load_skill(name)` tool | Agents without shell | LangChain |

There's also a third approach not in the spec but used implicitly:

| Approach | How it works | Best for |
|----------|-------------|----------|
| **System-prompt injection** | Host injects skill instructions into system prompt before LLM call | Library-level integration |

This third approach is what Yrden should use — the library controls the system prompt, so it can inject skill metadata and instructions directly.

---

## Research: How Skills Actually Execute (The Critical Details)

The spec describes *format*. This section describes *mechanism* — what actually happens at runtime when an agent uses a skill. This is the part that matters for implementation.

### Skills Are Prompt Injection, Not Function Calling

A skill is NOT a tool that returns a result. A skill is **instructions injected into the conversation** that the agent follows using its existing tools. The execution model:

```
1. Agent sees skill metadata in system prompt → knows what skills exist
2. Agent decides a skill matches the current task → activates it
3. Skill instructions are loaded into context (system prompt or user message)
4. Agent reads those instructions and follows them step by step
5. When instructions say "run scripts/analyze.py" → agent calls its Bash tool
6. When instructions say "see references/GUIDE.md" → agent calls its Read tool
7. Agent continues until task complete. Instructions remain in conversation.
```

There is no special "skill runtime." The agent's existing tools (Bash, Read, Write, Edit) are the execution engine. The skill just tells the agent *what to do with those tools*.

### What the Agent Needs to Execute Skills

This is the critical question for Yrden. A skill's instructions reference files and scripts. The agent needs tools to interact with them:

| Tool needed | What it does for skills | When it's used |
|-------------|------------------------|----------------|
| **Read/ReadFile** | Loads reference docs, templates, examples from skill directory | `"See references/CHECKLIST.md for details"` |
| **Bash/Shell** | Executes scripts bundled with the skill | `"Run python scripts/analyze.py input.pdf"` |
| **Write/WriteFile** | Creates output files as directed by instructions | `"Write the report to output.docx"` |
| **Edit** | Modifies existing files as directed | `"Edit the XML in unpacked/word/document.xml"` |
| **Grep/Glob** | Searches through files as directed | `"Find all TODO comments in the codebase"` |

**Without these tools, most real-world skills cannot execute.** A skill like `docx` needs Bash (to run `scripts/office/unpack.py`, `npm install -g docx`), Read (to load templates), Write (to create documents), and Edit (to modify XML). A simple instruction-only skill (like `code-review`) just needs the agent to produce text output — but even then, it might reference `references/CHECKLIST.md` which needs Read.

**Key implication for Yrden:** The built-in tools (ShellTool, ReadFileTool, WriteFileTool from the BuiltInTools design) are prerequisites for meaningful skill support. Skills without those tools are limited to "the agent reads instructions and outputs text" — useful but much less powerful.

### How the Agent Knows Where Skill Files Are

When instructions say `"Run scripts/analyze.py"`, the agent needs the absolute path. This is solved differently by each implementation:

| Implementation | How path is communicated |
|---------------|-------------------------|
| **Claude Code** | Injects skill directory path into conversation. Agent resolves relative paths. |
| **OpenAI Codex** | `render.rs` includes `(file: /absolute/path/to/SKILL.md)` in system prompt. Agent derives directory from path. |
| **LangChain** | `load_skill` tool returns instructions with paths pre-resolved. |

**For Yrden:** When injecting skill instructions, prepend the skill directory path. The agent then resolves `scripts/analyze.py` → `/Users/alice/.yrden/skills/pdf-processing/scripts/analyze.py`.

### How Claude Code Does It (The Meta-Tool Pattern)

Claude Code's implementation is the most sophisticated. It treats skills as a **meta-tool** — a tool called `Skill` sits alongside `Read`, `Bash`, `Write`, etc. in Claude's tool array.

**The Skill tool's description** is dynamically generated at runtime by aggregating all discoverable skills' names and descriptions:

```
"code-review": Review code for bugs, security vulnerabilities, and style issues.
"pdf-processing": Extract text and tables from PDF files.
"docx": Create, read, edit, or manipulate Word documents.
```

**When Claude calls the Skill tool**, it doesn't execute code — it injects messages:

1. **Visible message** (user sees): Status indicator showing which skill activated
2. **Hidden message** (Claude sees): Full SKILL.md content with `$ARGUMENTS` resolved

After injection, Claude processes the conversation normally — it reads the skill instructions and follows them using Read, Bash, Write, Edit, etc.

**How Claude selects which skill to use:** Pure LLM reasoning. No embeddings, no classifiers, no regex. Claude reads the skill descriptions from the Skill tool's definition and decides. The `description` field is everything — bad descriptions = skills never activate.

**Token budget for metadata:** 2% of context window (fallback: 16,000 chars). If you have too many skills, some descriptions get excluded.

### How OpenAI Codex Does It (Injection Pattern)

Codex's approach is simpler. Skills don't use a meta-tool:

1. At startup, `render.rs` generates a `## Skills` section in the system prompt listing each skill's name, description, and file path
2. When the user mentions `$skill-name` in a message, `injection.rs` parses it, reads the full SKILL.md from disk, and injects it as a `ResponseItem` into the conversation
3. The LLM can also implicitly activate a skill by recognizing a description match (no explicit `$skill-name` needed)
4. **Per-turn scoping:** Skills do NOT carry across turns unless re-mentioned

Codex also has a `$skill-installer` system skill (embedded in the binary) that downloads skills from GitHub as ZIP archives. The installer is itself a skill with Python scripts.

### The Description Field Is Everything

Both Claude Code and Codex use the `description` field as the **sole routing mechanism**. The LLM reads descriptions and decides. This has major implications:

**Good description (activates reliably):**
```yaml
description: "Use this skill whenever the user wants to create, read, edit, or manipulate Word documents (.docx files). Triggers include: any mention of \"Word doc\", \"word document\", \".docx\", or requests to produce professional documents with formatting like tables of contents, headings, page numbers, or letterheads."
```

**Bad description (never activates):**
```yaml
description: "Helps with documents."
```

The description must answer: *What does this skill do?* AND *When should the agent use it?* Including explicit trigger keywords dramatically improves activation rates.

---

## Research: Real-World Skill Anatomy

To understand what Yrden actually needs to support, let's examine real production skills from Anthropic's catalog (65K GitHub stars).

### Tier 1: Instruction-Only Skills (Simple)

**Example: `internal-comms`**
```
skills/internal-comms/
├── SKILL.md
└── examples/
    ├── 3p-updates.md
    ├── company-newsletter.md
    ├── faq-answers.md
    └── general-comms.md
```

**What the agent does:**
1. Reads SKILL.md instructions
2. Identifies communication type from user request
3. Uses Read tool to load the appropriate template from `examples/`
4. Follows the template to write the communication

**Tools needed:** Read (to load templates). That's it. No scripts, no Bash.

**Yrden support:** Works with just ReadFileTool. The agent reads instructions from the system prompt and loads reference files on demand.

### Tier 2: Script-Heavy Skills (Complex)

**Example: `docx` (Word document creation/editing)**
```
skills/docx/
├── SKILL.md              # 400+ lines of instructions
└── scripts/
    ├── accept_changes.py
    ├── comment.py
    └── office/
        ├── unpack.py     # Extract .docx (ZIP) to XML
        ├── pack.py       # Repack XML to .docx
        ├── validate.py   # Validate document structure
        ├── soffice.py    # LibreOffice wrapper
        ├── helpers/      # Shared utilities
        ├── schemas/      # XML schemas
        └── validators/   # Document validators
```

**What the agent does (create new document):**
1. Reads SKILL.md instructions (knows docx-js API, page sizes, formatting rules)
2. Generates JavaScript code using `docx` npm package
3. Runs `Bash: node create-doc.js` to create the document
4. Runs `Bash: python scripts/office/validate.py doc.docx` to validate
5. If validation fails: `Bash: python scripts/office/unpack.py doc.docx unpacked/`
6. Uses Edit tool to fix XML in `unpacked/word/document.xml`
7. Runs `Bash: python scripts/office/pack.py unpacked/ output.docx --original doc.docx`

**What the agent does (edit existing document):**
1. `Bash: python scripts/office/unpack.py document.docx unpacked/`
2. Read tool to inspect XML files in `unpacked/word/`
3. Edit tool to modify XML (tracked changes, comments, content)
4. `Bash: python scripts/comment.py unpacked/ 0 "Comment text"`
5. `Bash: python scripts/office/pack.py unpacked/ output.docx --original document.docx`

**Tools needed:** Bash (runs 6+ different Python scripts, npm commands), Read (inspects XML), Write (creates JS files), Edit (modifies XML). Also requires Python, Node.js, npm, LibreOffice, Poppler to be installed on the system.

**Yrden support:** Requires ShellTool + ReadFileTool + WriteFileTool at minimum. The skill's scripts are executed via ShellTool. The agent must know the skill directory path to find `scripts/`.

### Tier 3: Multi-Reference Skills (Progressive Disclosure)

**Example: `pdf` (PDF manipulation)**
```
skills/pdf/
├── SKILL.md          # Core instructions + quick reference table
├── forms.md          # Detailed form-filling guide (loaded on demand)
├── reference.md      # Advanced techniques (loaded on demand)
└── scripts/
    ├── check_fillable_fields.py
    ├── extract_form_field_info.py
    ├── fill_fillable_fields.py
    ├── fill_pdf_form_with_annotations.py
    ├── extract_form_structure.py
    ├── convert_pdf_to_images.py
    ├── check_bounding_boxes.py
    └── create_validation_image.py
```

**Progressive disclosure in action:**
1. SKILL.md is always loaded (tier 2) — contains a quick reference table directing to forms.md and reference.md
2. If user wants form filling: agent reads `forms.md` (tier 3) for the two-path workflow (fillable vs annotation-based)
3. If user wants advanced features: agent reads `reference.md` (tier 3) for pypdfium2, pdf-lib, advanced poppler
4. Scripts are only executed when needed — `check_fillable_fields.py` first, then branch based on result

**Tools needed:** Bash (8 Python scripts), Read (2 reference docs + SKILL.md), Write (output files). System dependencies: Python (pypdf, pdfplumber, reportlab), poppler-utils, ImageMagick, qpdf.

### Tier 4: Creative/Generative Skills (Template-Based)

**Example: `algorithmic-art`**
```
skills/algorithmic-art/
├── SKILL.md
└── templates/
    ├── generator_template.js
    └── viewer.html
```

**What the agent does:**
1. Reads SKILL.md instructions (art philosophy, p5.js patterns)
2. Reads `templates/viewer.html` as a REQUIRED starting point
3. Creates artistic philosophy as `.md` file (Write tool)
4. Generates self-contained HTML with p5.js (Write tool)
5. No Bash needed — output is pure HTML/JS

**Tools needed:** Read (templates), Write (output files). No Bash, no system dependencies.

### Tier 5: QA-Loop Skills (Iterative Verification)

**Example: `pptx` (PowerPoint creation)**
```
skills/pptx/
├── SKILL.md          # Core workflow + design guidance
├── editing.md        # Template-based editing workflow
├── pptxgenjs.md      # PptxGenJS API reference
└── scripts/
    ├── thumbnail.py   # Generate visual grid of slides
    ├── add_slide.py   # Duplicate slide in unpacked XML
    ├── clean.py       # Remove orphaned files
    └── office/        # Shared unpack/pack/validate/soffice
```

**The QA loop pattern:**
1. Agent creates/edits presentation using PptxGenJS or XML editing
2. `Bash: python scripts/office/soffice.py --headless --convert-to pdf output.pptx`
3. `Bash: pdftoppm -jpeg -r 150 output.pdf slide` (convert to images)
4. Agent visually inspects images (or spawns a subagent for QA)
5. If issues found: fix and repeat from step 1
6. Iterate until quality is acceptable

**Key insight:** This pattern requires the agent to run commands, inspect results, make decisions, and loop. It's a multi-iteration workflow within a single skill execution. The agent loop's iteration support is what makes this possible.

### Summary: What Real Skills Actually Need

| Capability | % of Anthropic's skills that need it | Yrden component |
|-----------|--------------------------------------|-----------------|
| Read files from skill directory | 14/16 (88%) | ReadFileTool |
| Execute scripts via shell | 11/16 (69%) | ShellTool |
| Write output files | 12/16 (75%) | WriteFileTool |
| Edit existing files | 6/16 (38%) | (future EditFileTool) |
| System dependencies (Python, Node, etc.) | 11/16 (69%) | User's responsibility |
| Multi-iteration loops | 4/16 (25%) | Agent loop (already supported) |
| Subagent spawning | 2/16 (13%) | (future) |
| Visual inspection (images) | 3/16 (19%) | (future, multimodal) |

**The minimum viable tool set for skills: ReadFileTool + ShellTool + WriteFileTool.** These three tools (already designed in BuiltInTools.md) enable 88% of the Anthropic skills catalog. Without ShellTool, you can only support instruction-only and template-based skills (~30% of the catalog).

---

## Research: Beyond the Standard — Code-Based Skills

The Agent Skills standard is file-based (SKILL.md). Several frameworks implement a complementary code-based model:

### Microsoft Semantic Kernel "Plugins" (formerly "Skills")

Renamed from "skills" to "plugins" to align with OpenAI's plugin ecosystem. Fundamentally different from Agent Skills — these are **typed code** invoked through LLM function calling:

```csharp
public class LightsPlugin {
    [KernelFunction, Description("Toggle a light on or off")]
    public async Task<Light> ToggleLight(
        [Description("The ID of the light")] int id,
        [Description("Whether to turn on")] bool isOn
    ) { ... }
}

kernel.Plugins.AddFromType<LightsPlugin>("Lights");
```

Key difference: Semantic Kernel plugins are executable functions with typed parameters. Agent Skills are instruction packages. SK plugins use function calling; Agent Skills use prompt injection.

### CrewAI

CrewAI has no dedicated skills abstraction. Agent capabilities emerge from:
- **Role configuration** — role, goal, backstory define specialization
- **Tool assignment** — each agent gets specific tools
- **Delegation** — agents can delegate to specialists

A "code review skill" in CrewAI is an agent with `role="Senior Security Reviewer"` and relevant tools. Not a loadable package.

### Yrden's CLAUDE.md Vision

The CLAUDE.md already sketches a code-based Skill protocol:

```swift
protocol Skill {
    var name: String { get }
    var description: String { get }
    var tools: [any Tool] { get }
    var systemPrompt: String { get }
    func preprocess(_ input: String) -> String
}
```

This is the Semantic Kernel model — skills as typed code that extend agent behavior programmatically.

### Key Insight: Two Complementary Models

| Model | What it is | Strengths | Weaknesses |
|-------|-----------|-----------|------------|
| **File-based (Agent Skills standard)** | SKILL.md with instructions | Portable, shareable, works across agents, non-developers can author | No type safety, no tools, opaque to the compiler |
| **Code-based (Swift protocol)** | `Skill` conformance with tools + prompts | Type-safe, can carry tools, composable with Swift's type system | Not portable, requires compilation, developer-only |

These are not competing models — they serve different use cases. A library can support both.

---

## Research: Existing Swift Implementations

**There are none.**

The only Swift-adjacent project is [swiftwasm/skills](https://github.com/swiftwasm/skills) (26 stars) — a collection of 3 Agent Skills *for* Swift WebAssembly development (SKILL.md files teaching agents about SwiftWasm). It's a consumer of skills, not a framework.

No Swift AI library (SwiftAI, SwiftAgent, AgentSDK-Swift, LLM.swift) implements any form of skills system — neither the file-based standard nor a code-based protocol.

---

## Research: Yrden's Current Architecture

The agent currently accepts tools and a static system prompt:

```swift
public actor Agent<Output: SchemaType> {
    public let model: any Model
    public let systemPrompt: String
    public let tools: [any Tool]
    public let outputValidators: [OutputValidator<Output>]
    // ...
}
```

**Integration points for skills:**

1. **System prompt** — Skills can extend it with metadata (tier 1) and instructions (tier 2)
2. **Tools array** — Code-based skills can contribute additional tools
3. **Output validators** — Skills could provide domain-specific validation
4. **No changes to the agent loop** — Skills are resolved before the loop starts. The agent loop sees tools and a system prompt; it doesn't need to know about skills

**Existing patterns that help:**
- `[any Tool]` existential arrays — code-based skills can contribute tools without type erasure issues
- Tool name collision detection — Agent already auto-renames colliding tool names
- `ToolContext` — available during tool execution for skills that need runtime context
- Progressive loading fits naturally into the system prompt construction

---

## Approaches

### Approach A: File-Based Only (Agent Skills Standard)

Implement the open standard. Parse SKILL.md, inject into system prompt, load resources on demand.

**Scope:** Small (~300-400 lines of code)

**New types:**
```swift
/// Parsed SKILL.md metadata
public struct SkillMetadata: Sendable {
    public let name: String
    public let description: String
    public let license: String?
    public let compatibility: String?
    public let metadata: [String: String]
    public let allowedTools: [String]?
    public let path: String  // absolute path to skill directory
}

/// A skill loaded from the filesystem
public struct FileSkill: Sendable {
    public let metadata: SkillMetadata
    public let instructions: String   // markdown body (tier 2)
    public let skillDirectory: String  // for resolving references/scripts/assets
}

/// Discovers and loads skills from configured directories
public struct SkillLoader: Sendable {
    public init(searchPaths: [String])

    /// Scan all search paths, return metadata for discovered skills (tier 1)
    public func discoverSkills() throws -> [SkillMetadata]

    /// Load full skill instructions (tier 2)
    public func loadSkill(named: String) throws -> FileSkill

    /// Load a resource file from a skill (tier 3)
    public func loadResource(skill: String, path: String) throws -> String
}
```

**How it integrates with Agent:**

```swift
// User discovers skills at startup
let loader = SkillLoader(searchPaths: [
    "~/.yrden/skills",
    ".yrden/skills"
])
let available = try loader.discoverSkills()

// Inject metadata into system prompt (tier 1)
let skillsPrompt = SkillPromptBuilder.metadataXML(available)
let systemPrompt = """
You are a helpful assistant.

\(skillsPrompt)

When a task matches a skill, load its full instructions before proceeding.
"""

// When skill activates (tier 2), prepend to conversation
let skill = try loader.loadSkill(named: "code-review")
let messages: [Message] = [
    .system(skill.instructions),
    .user("Review this PR: ...")
]

let agent = try Agent<Report>(model: claude, systemPrompt: systemPrompt)
let run = try await agent.run("Review this PR", messageHistory: messages)
```

**Pros:**
- Full interoperability with the Agent Skills ecosystem
- Users can drop in any existing skill from Anthropic's catalog, community repos, etc.
- Minimal code, minimal surface area
- Non-developers can author skills (just markdown)

**Cons:**
- No type safety — skills are opaque text
- No tool contribution — skills can reference tools by name but can't provide new ones
- Skill activation is manual — the caller decides which skill to load (or builds their own matching logic)
- No Swift-native programmatic skills

**YAML dependency:** Requires a YAML parser. Options:
- [Yams](https://github.com/jpsim/Yams) — mature, widely used, 1K+ stars
- Hand-rolled frontmatter parser — YAML frontmatter is simple enough (key: value lines between `---` delimiters) that a minimal parser avoids the dependency

---

### Approach B: Code-Based Only (Swift Protocol)

Define a `Skill` protocol. Skills are Swift types that contribute tools, system prompt extensions, and preprocessing.

**Scope:** Medium (~500-600 lines of code)

**New types:**
```swift
/// A composable capability that extends agent behavior.
public protocol Skill: Sendable {
    /// Unique identifier
    var name: String { get }

    /// Describes what this skill does and when to use it
    var description: String { get }

    /// Additional tools this skill provides
    var tools: [any Tool] { get }

    /// Instructions appended to the system prompt when active
    var instructions: String { get }

    /// Transform user input before sending to LLM (optional)
    func preprocess(_ input: String) -> String
}

// Sensible defaults
extension Skill {
    public var tools: [any Tool] { [] }
    public var instructions: String { "" }
    public func preprocess(_ input: String) -> String { input }
}
```

**How it integrates with Agent:**

```swift
// Option 1: Skills as Agent init parameter
let agent = try Agent<Report>(
    model: claude,
    systemPrompt: "You are a helpful assistant.",
    tools: [searchTool, calcTool],
    skills: [CodeReviewSkill(), SecurityAuditSkill()]
)
// Agent internally:
// - Merges skill.tools into tools array
// - Appends skill.instructions to system prompt
// - Wraps run() to apply skill.preprocess()

// Option 2: Skills compose externally (no Agent changes)
let skills: [any Skill] = [CodeReviewSkill(), SecurityAuditSkill()]
let allTools = [searchTool, calcTool] + skills.flatMap(\.tools)
let fullPrompt = basePrompt + skills.map(\.instructions).joined(separator: "\n\n")

let agent = try Agent<Report>(
    model: claude,
    systemPrompt: fullPrompt,
    tools: allTools
)
```

**Example skill:**
```swift
struct CodeReviewSkill: Skill {
    let name = "code-review"
    let description = "Review code for bugs, security vulnerabilities, and style issues."

    var tools: [any Tool] {
        [LintTool(config: .standard)]
    }

    var instructions: String {
        """
        When reviewing code:
        1. Check for security vulnerabilities (SQL injection, XSS, command injection)
        2. Identify performance issues (N+1 queries, unnecessary allocations)
        3. Check error handling (are errors propagated? are edge cases covered?)
        4. Review naming and clarity
        5. Provide findings grouped by severity: critical, warning, suggestion
        """
    }
}
```

**Pros:**
- Type-safe, composable, testable
- Skills can contribute tools — a "database" skill can bring a QueryTool
- Preprocessor enables skill-specific input transformation
- Swift-native — IDE autocomplete, compile-time checking
- Skills can capture dependencies via constructor injection (same pattern as tools)

**Cons:**
- No interoperability with Agent Skills ecosystem
- Skills must be compiled Swift code — non-developers can't author them
- Not portable across agents
- Designing the protocol surface is the hard part — getting it wrong means breaking changes later

---

### Approach C: Hybrid (Recommended)

Support both models. Define a `Skill` protocol (code-based), implement `FileSkill` as a conformer that loads from SKILL.md (file-based). The agent doesn't care which kind it gets.

**Scope:** Medium (~700-800 lines of code)

**Core protocol (same as Approach B):**
```swift
public protocol Skill: Sendable {
    var name: String { get }
    var description: String { get }
    var tools: [any Tool] { get }
    var instructions: String { get }
    func preprocess(_ input: String) -> String
}
```

**File-based conformer (bridges to Approach A):**
```swift
/// A skill loaded from an Agent Skills standard directory (SKILL.md).
public struct FileSkill: Skill, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let skillDirectory: String
    public let rawMetadata: SkillMetadata

    // File-based skills don't contribute tools
    public var tools: [any Tool] { [] }

    /// Load from a skill directory containing SKILL.md
    public init(path: String) throws

    /// Load a resource file (references/, scripts/, assets/)
    public func loadResource(_ relativePath: String) throws -> String
}
```

**Unified loader:**
```swift
public struct SkillRegistry: Sendable {
    private var skills: [String: any Skill] = [:]

    /// Register a code-based skill
    public mutating func register(_ skill: any Skill)

    /// Discover and register file-based skills from directories
    public mutating func discover(in searchPaths: [String]) throws

    /// All registered skills (code + file)
    public var all: [any Skill] { Array(skills.values) }

    /// Get a specific skill by name
    public func skill(named: String) -> (any Skill)?

    /// Generate metadata XML for system prompt injection (tier 1)
    public func metadataPrompt() -> String
}
```

**How it integrates with Agent:**

```swift
// Register both code-based and file-based skills
var registry = SkillRegistry()
registry.register(CodeReviewSkill(lintConfig: .strict))
try registry.discover(in: ["~/.yrden/skills", ".yrden/skills"])

// Agent accepts skills
let agent = try Agent<Report>(
    model: claude,
    systemPrompt: "You are a helpful assistant.",
    tools: [searchTool],
    skills: registry.all
)

// Or: agent with specific skills
let agent = try Agent<Report>(
    model: claude,
    tools: [searchTool],
    skills: [
        CodeReviewSkill(),                                    // code-based
        try FileSkill(path: ".yrden/skills/pdf-processing")   // file-based
    ]
)
```

**Agent integration (internal):**

```swift
public actor Agent<Output: SchemaType> {
    public let skills: [any Skill]

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [any Tool] = [],
        skills: [any Skill] = [],    // New parameter
        // ... existing params
    ) throws {
        // 1. Merge skill tools into tools array
        let skillTools = skills.flatMap(\.tools)
        let allTools = tools + skillTools

        // 2. Check for name collisions (existing logic handles this)
        // ...

        // 3. Build system prompt with skill metadata
        let skillMetadata = skills.isEmpty ? "" : Self.buildSkillsPrompt(skills)
        self.systemPrompt = systemPrompt + skillMetadata

        // 4. Store skills for activation during runs
        self.skills = skills
    }
}
```

**Pros:**
- Best of both worlds — ecosystem interop + type safety
- `FileSkill` is a first-class `Skill`, not a second-class adapter
- `SkillRegistry` unifies discovery across both models
- Agent doesn't know or care about the skill's backing — protocol abstraction works
- Non-developers author SKILL.md files, developers author `Skill` conformances
- Can evolve independently — new protocol features don't break file-based skills, new spec features don't break code-based skills

**Cons:**
- Larger surface area than either model alone
- YAML parsing dependency (or hand-rolled parser)
- Two mental models to document and maintain
- Risk of feature drift between the two models

**Tradeoff: YAML parsing.** The frontmatter format is simple:
```yaml
---
name: skill-name
description: What it does
license: Apache-2.0
metadata:
  author: org
  version: "1.0"
---
```

This is flat key-value pairs with one nested map (`metadata`). A hand-rolled parser handles this in ~80 lines without adding Yams as a dependency. Full YAML (anchors, multi-line strings, flow sequences) is not needed. If we later need full YAML, Yams can be added as an optional dependency.

---

## Approach Comparison

| Criterion | A: File-Based | B: Code-Based | C: Hybrid |
|-----------|--------------|---------------|-----------|
| Ecosystem interop | Full | None | Full |
| Type safety | None | Full | Both |
| Tool contribution | No | Yes | Yes |
| Non-dev authoring | Yes | No | Yes (file path) |
| Agent init changes | None (external) | `skills:` param | `skills:` param |
| New dependencies | YAML parser | None | YAML parser |
| Lines of code | ~300-400 | ~500-600 | ~700-800 |
| Risk | Low | Medium (protocol design) | Medium |

---

## Recommended Design: Approach C (Hybrid)

### Decision 1: Skill Protocol — Minimal Surface

Start with the smallest useful protocol. Skills provide two things: knowledge (instructions) and capabilities (tools). Everything else is optional.

```swift
public protocol Skill: Sendable {
    /// Unique identifier (lowercase, hyphens, matches Agent Skills naming rules)
    var name: String { get }

    /// Describes what this skill does and when to use it (max 1024 chars)
    var description: String { get }

    /// Instructions loaded when skill is activated (tier 2)
    var instructions: String { get }

    /// Additional tools this skill provides (merged into agent's tool array)
    var tools: [any Tool] { get }
}

extension Skill {
    public var tools: [any Tool] { [] }
    public var instructions: String { "" }
}
```

**What we deliberately exclude (for now):**
- `preprocess(_:)` / `postprocess(_:)` — adds complexity, unclear use case. Can be added later without breaking changes.
- `outputValidators` — skills validating output is a good idea but requires generic `Output` on the protocol, which would prevent `[any Skill]` arrays. Keep validators on Agent.
- `hooks` / lifecycle callbacks — Claude Code has these but they're complex. Wait for real demand.
- `context: fork` / subagent isolation — requires deep agent loop changes. Future work.

**Why no `Sendable` constraint on protocol members:** `name`, `description`, `instructions` are `String` (already `Sendable`). `tools` returns `[any Tool]` where `Tool: Sendable`. The protocol itself requires `: Sendable`. No additional constraints needed.

### Decision 2: FileSkill — Agent Skills Standard Conformance

`FileSkill` conforms to `Skill` by loading from a SKILL.md directory.

```swift
public struct FileSkill: Skill, Sendable {
    public let name: String
    public let description: String
    public let instructions: String
    public let license: String?
    public let compatibility: String?
    public let skillMetadata: [String: String]
    public let allowedToolNames: [String]?
    public let skillDirectory: String

    // File-based skills don't contribute tools
    public var tools: [any Tool] { [] }

    /// Load from a directory containing SKILL.md
    /// Validates: name format, directory name matches, required fields present
    public init(directory: String) throws

    /// Load a resource file relative to skill directory
    /// Example: loadResource("references/CHECKLIST.md")
    public func loadResource(_ relativePath: String) throws -> String

    /// List available resources (scripts/, references/, assets/)
    public func availableResources() throws -> [String]
}
```

**Path resolution for skill resources:**

When instructions say `"Run scripts/analyze.py"`, the agent needs the absolute path. `FileSkill` prepends a header to instructions that includes the skill directory:

```
[Skill: code-review | Directory: /Users/alice/.yrden/skills/code-review]

# Code Review
## Steps
1. Read the changed files
2. Run the linting script: scripts/lint-check.sh
...
```

The agent resolves `scripts/lint-check.sh` → `/Users/alice/.yrden/skills/code-review/scripts/lint-check.sh`. This matches Codex's approach of including `(file: /absolute/path)` in the system prompt.

**Why the agent can do this without special handling:** The agent already has ReadFileTool and ShellTool. When it reads skill instructions that say "run `scripts/X.py`" and sees the directory header, it constructs the full path and calls ShellTool. No special "skill execution engine" is needed — the LLM's reasoning handles path resolution.

**Validation rules (from the spec):**
- `name`: 1-64 chars, lowercase alphanumeric + hyphens, no leading/trailing/consecutive hyphens
- `name` must match parent directory name
- `description`: 1-1024 chars, non-empty
- `SKILL.md` must exist in the directory
- YAML frontmatter must be delimited by `---`

**Frontmatter parsing (hand-rolled, ~80 lines):**
```swift
struct FrontmatterParser {
    /// Parse YAML frontmatter from SKILL.md content.
    /// Returns (frontmatter dict, markdown body).
    /// Handles: string values, nested string maps (metadata), optional fields.
    /// Does NOT handle: arrays, multi-line strings, anchors, flow syntax.
    static func parse(_ content: String) throws -> (fields: [String: Any], body: String)
}
```

**Quoted YAML values:** The `description` field in real-world skills often uses double-quoted YAML strings with escaped inner quotes:
```yaml
description: "Use this skill whenever the user mentions \"Word doc\" or \".docx\""
```
The parser must handle double-quoted values with escaped quotes. This is still simple enough to hand-roll (~15 extra lines over naive key-value parsing).

We avoid the Yams dependency because:
1. Agent Skills frontmatter is intentionally simple — flat key-value with one optional nested map
2. Adding a dependency for ~80 lines of parsing is not worth the transitive dependency cost
3. If full YAML is ever needed, Yams can be added later without changing the public API

### Decision 3: SkillRegistry — Unified Discovery

```swift
public struct SkillRegistry: Sendable {
    /// Register a code-based skill
    public mutating func register(_ skill: any Skill) throws

    /// Discover file-based skills in directories
    /// Scans each path for subdirectories containing SKILL.md
    public mutating func discover(in searchPaths: [String]) throws

    /// All registered skills (code + file, sorted by name)
    public var all: [any Skill]

    /// Lookup by name (O(1))
    public func skill(named: String) -> (any Skill)?

    /// Generate system prompt metadata for all skills (tier 1)
    /// Returns XML in the format recommended by the spec for Claude models
    public func metadataPrompt() -> String
}
```

**Name collision handling:** Throw on duplicate names. Skills are identified by name; collisions indicate misconfiguration, not something to auto-resolve (unlike tools, where the Agent auto-renames collisions because tool names come from different sources that can't coordinate).

**Discovery order:** Directories are scanned in the order provided. If the same skill name appears in multiple directories, the first one wins (matching Claude Code's precedence model).

**Metadata prompt format (following the spec's recommendation for Claude models):**
```xml
<available-skills>
  <skill>
    <name>code-review</name>
    <description>Review code for bugs, security vulnerabilities, and style issues.</description>
  </skill>
  <skill>
    <name>pdf-processing</name>
    <description>Extract text and tables from PDF files.</description>
  </skill>
</available-skills>
```

### Decision 4: Agent Integration — Skills as Init Parameter

Add `skills:` to Agent's initializer. The agent composes skills at construction time.

```swift
public actor Agent<Output: SchemaType> {
    public let skills: [any Skill]

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [any Tool] = [],
        skills: [any Skill] = [],    // New parameter
        maxIterations: Int = 10,
        // ... remaining existing params
    ) throws {
        // Merge skill tools into tools array
        let skillTools = skills.flatMap(\.tools)
        let allTools = tools + skillTools

        // Existing tool name collision detection applies to skill tools too
        var seenToolNames: Set<String> = []
        for tool in allTools {
            if !seenToolNames.insert(tool.name).inserted {
                throw AgentError<Output>.invalidConfiguration(
                    "Duplicate tool name: '\(tool.name)'"
                )
            }
        }

        self.tools = allTools
        self.skills = skills

        // Build system prompt: base + skill metadata + skill instructions
        var prompt = systemPrompt
        if !skills.isEmpty {
            let metadata = skills.map { skill in
                "<skill>\n  <name>\(skill.name)</name>\n  <description>\(skill.description)</description>\n</skill>"
            }.joined(separator: "\n")
            prompt += "\n\n<available-skills>\n\(metadata)\n</available-skills>"
        }
        self.systemPrompt = prompt

        // ... rest of existing init
    }
}
```

**Design choice: All skills active at init vs. on-demand activation.**

The spec describes on-demand activation (tier 1 metadata at startup, tier 2 instructions loaded when matched). This matters for agents with many skills and limited context. For v1, we take a simpler approach:

- **All skill instructions are included in the system prompt at init** (tier 1 + tier 2 merged)
- This is simpler, avoids mid-conversation prompt modification, and works well for agents with 1-5 skills
- For agents with 10+ skills, this wastes context. On-demand activation (where the agent decides which skill to load) is future work

**Tradeoff:** Simpler implementation at the cost of context efficiency. For the typical use case (1-5 skills, <25K tokens total), this is fine. The progressive disclosure optimization can be added in v2 without changing the public API — it's an internal agent behavior change.

### Decision 5: Skill Activation — Eager (v1), Progressive (v2)

**v1 (this design):** All skill instructions are injected into the system prompt at Agent construction. The LLM sees everything.

**v2 (future):** Only metadata is injected at startup. A `SkillTool` meta-tool lets the LLM decide which skill to activate. This matches the spec's progressive disclosure model and Claude Code's architecture.

```swift
// v2 sketch (not implemented now)

/// Internal meta-tool that lets the agent activate skills on demand.
/// Added automatically when skills are registered.
struct SkillTool: TypedTool {
    let registry: SkillRegistry

    var name: String { "activate_skill" }
    var description: String {
        // Dynamically built from all skill descriptions (tier 1)
        var desc = "Activate a skill to load specialized instructions for a task.\n\n"
        desc += "Available skills:\n"
        for skill in registry.all {
            desc += "- \"\(skill.name)\": \(skill.description)\n"
        }
        return desc
    }

    @Schema(description: "Activate a skill by name")
    struct Args {
        @Guide(description: "Name of the skill to activate")
        let skillName: String

        @Guide(description: "Arguments to pass to the skill")
        let arguments: String?
    }

    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<String> {
        guard let skill = registry.skill(named: arguments.skillName) else {
            return .failure("Unknown skill: \(arguments.skillName). Available: \(registry.all.map(\.name).joined(separator: ", "))")
        }
        // Return full instructions (tier 2) — enters context as tool result
        var instructions = skill.instructions
        if let args = arguments.arguments {
            instructions += "\n\nARGUMENTS: \(args)"
        }
        return .success(instructions)
    }
}
```

**Why this works:** The LLM sees skill descriptions in the tool definition (tier 1, ~100 tokens each). When it decides a skill is relevant, it calls `activate_skill` and receives the full instructions as a tool result (tier 2). The instructions then guide the rest of the conversation. This is essentially the LangChain `load_skill` pattern and is the tool-based integration approach from the spec.

**Token savings:** With 10 skills averaging 3000 tokens each, eager loading costs 30K tokens of system prompt. Progressive loading costs ~1000 tokens of metadata + 3000 tokens for the one activated skill = 4000 tokens.

### Decision 6: BuiltInTools Are a Prerequisite for Meaningful Skills

Based on analyzing 16 production skills from Anthropic's catalog:

| Skill complexity | Tools needed | % of catalog |
|-----------------|-------------|-------------|
| Instruction-only (text output) | None beyond base LLM | 12% |
| Template-based (load + follow) | ReadFileTool | 19% |
| Script-driven (run + inspect) | ReadFileTool + ShellTool + WriteFileTool | 69% |

**Decision:** Skills support should be designed alongside BuiltInTools, not independently. The `BuiltInTools` factory already creates ShellTool, ReadFileTool, WriteFileTool with shared PathValidator and directory restrictions. Skills need these tools to function.

**Recommended setup for skills:**
```swift
// Skills need tools to execute their scripts and references
let tools = try await BuiltInTools(workingDirectory: projectDir)

var registry = SkillRegistry()
try registry.discover(in: [".yrden/skills", "~/.yrden/skills"])

let agent = try Agent<Report>(
    model: claude,
    systemPrompt: "You are a helpful assistant.",
    tools: tools.all,          // Shell + ReadFile + WriteFile
    skills: registry.all       // Skills that use those tools
)
```

**What happens when the agent runs a skill with scripts:**
1. Agent reads skill instructions from system prompt
2. Instructions say: `"Run python scripts/check_fillable_fields.py input.pdf"`
3. Agent sees skill directory header: `[Directory: /Users/alice/.yrden/skills/pdf]`
4. Agent calls ShellTool: `python /Users/alice/.yrden/skills/pdf/scripts/check_fillable_fields.py input.pdf`
5. ShellTool executes, returns stdout/stderr (with truncation/spillover if large)
6. Agent reads the output and continues following instructions

**What happens when the agent reads a skill reference:**
1. Instructions say: `"For form filling details, see forms.md"`
2. Agent calls ReadFileTool: `/Users/alice/.yrden/skills/pdf/forms.md`
3. ReadFileTool returns file content (with line limits, truncation)
4. Agent uses the reference content to guide its work

No special skill execution engine. The LLM follows instructions using tools it already has.

---

## End-to-End Example: PDF Form Filling

To make the integration concrete, here's what happens when a user says "Fill out this tax form" with the `pdf` skill installed:

```
User: "Fill out form W-9 in /Downloads/w9.pdf with my company info"

Agent thinking:
  → Sees <available-skills> in system prompt
  → "pdf" skill matches: "Extract text and tables from PDF files, fill forms..."
  → Reads pdf skill instructions from system prompt

Agent follows skill instructions step by step:

1. Check if form is fillable:
   → ShellTool: python /path/skills/pdf/scripts/check_fillable_fields.py /Downloads/w9.pdf
   ← Output: "Form has 15 fillable fields"

2. Extract field info:
   → ShellTool: python /path/skills/pdf/scripts/extract_form_field_info.py /Downloads/w9.pdf fields.json
   ← Output: "Extracted 15 fields to fields.json"

3. Read field structure:
   → ReadFileTool: fields.json
   ← Returns JSON with field names, types, positions

4. Skill instructions say "For fillable forms, see forms.md":
   → ReadFileTool: /path/skills/pdf/forms.md
   ← Returns detailed form-filling workflow

5. Create field values JSON:
   → WriteFileTool: field_values.json with {"name": "ACME Corp", "ein": "12-3456789", ...}

6. Fill the form:
   → ShellTool: python /path/skills/pdf/scripts/fill_fillable_fields.py /Downloads/w9.pdf field_values.json /Downloads/w9-filled.pdf
   ← Output: "Filled 15/15 fields, saved to w9-filled.pdf"

Agent: "Done. Filled W-9 saved to /Downloads/w9-filled.pdf with your company info."
```

Every step uses standard Yrden tools (ShellTool, ReadFileTool, WriteFileTool). The skill provided the *expertise* (which scripts to run, in what order, with what arguments). The tools provided the *capability*.

---

## File Layout

```
Sources/Yrden/Skills/
├── Skill.swift              # Skill protocol + defaults
├── FileSkill.swift           # Agent Skills standard loader
├── FrontmatterParser.swift   # YAML frontmatter parsing (hand-rolled)
├── SkillRegistry.swift       # Discovery + registration
└── SkillPromptBuilder.swift  # System prompt XML generation

Tests/YrdenTests/Unit/Skills/
├── SkillProtocolTests.swift
├── FileSkillTests.swift
├── FrontmatterParserTests.swift
├── SkillRegistryTests.swift
└── SkillPromptBuilderTests.swift
```

**Modified files:**
- `Sources/Yrden/Agent/Agent.swift` — add `skills: [any Skill]` parameter to init
- No other existing files modified

---

## Test Strategy

### FrontmatterParser
- Valid frontmatter with all fields → parsed correctly
- Required fields only (name, description) → parsed, optionals nil
- Missing `name` → error with message
- Missing `description` → error with message
- Empty description → error
- Name exceeding 64 chars → error
- Name with uppercase → error
- Name with leading/trailing hyphen → error
- Name with consecutive hyphens → error
- Nested metadata map → parsed as `[String: String]`
- No frontmatter delimiters → error
- Empty body after frontmatter → valid (instructions is empty string)
- Frontmatter + body separation → body starts after closing `---`

### FileSkill
- Valid skill directory → loads name, description, instructions
- Directory name doesn't match `name` field → error
- Missing SKILL.md → error
- `loadResource("references/GUIDE.md")` → returns file content
- `loadResource("../escape")` → error (path traversal)
- `availableResources()` → lists files in scripts/, references/, assets/
- Skill with only SKILL.md (no optional dirs) → valid
- Conforms to `Skill` protocol → `tools` returns `[]`

### SkillRegistry
- Register code-based skill → discoverable by name
- Discover file-based skills in directory → all loaded
- Duplicate name → throws error
- `skill(named:)` → returns correct skill or nil
- `all` → sorted by name
- `metadataPrompt()` → valid XML with all skills
- Empty registry → `metadataPrompt()` returns empty string
- Discovery with empty directory → no skills added
- Discovery with nested invalid skill → skipped with warning (not error)
- Multiple search paths → first occurrence wins

### SkillPromptBuilder
- Single skill → valid XML
- Multiple skills → valid XML, sorted
- Description with XML-special chars (`<`, `>`, `&`) → escaped
- Empty skills array → empty string

### Agent Integration
- Agent with skills → system prompt contains skill metadata
- Agent with skills contributing tools → tools merged, accessible
- Skill tool name collides with existing tool → error thrown
- Agent with no skills → behaves exactly as before (backward compatible)
- Agent with file-based + code-based skills → both work

---

## Open Questions

### 1. Should skill instructions go in system prompt or user messages?

Claude Code injects skill content as **two user messages** — one visible (status indicator) and one hidden (`isMeta: true`). The spec doesn't prescribe either approach.

| Approach | How it works | Pros | Cons |
|----------|-------------|------|------|
| **System prompt** | Prepend instructions to system prompt at Agent init | Simple, provider-agnostic, one-time | Inflates system prompt permanently; wastes tokens for multi-turn conversations where skill is only needed once |
| **User messages** | Inject as conversation messages when skill activates | Can be added mid-conversation; matches Claude Code; instructions are "closer" to the user request | Requires message history manipulation; confuses conversation flow |
| **Tool result** | SkillTool returns instructions as tool result | Natural progressive disclosure; LLM decides when to load; instructions are contextually positioned | Requires v2 SkillTool; adds a tool call round-trip |

Decision: System prompt for v1 (simplest). The v2 SkillTool pattern (tool result) is the better long-term approach, matching both Claude Code's and LangChain's architecture.

### 2. Should we validate the `allowed-tools` field?

The spec includes `allowed-tools` as experimental. Claude Code uses it to restrict which tools a skill can invoke — when a skill specifies `allowed-tools: Bash(git:*) Read`, those tools are **pre-approved** (no user confirmation needed) while all others require approval.

For v1: Parse and store the field but don't enforce it. Enforcement requires:
- Tracking which skill is "active" during execution
- Modifying the tool approval flow in the agent loop to check skill permissions
- Potentially restricting tool calls mid-conversation (complex with the current beforeTools phase)

This is significant complexity for an experimental field. Store it, document it, implement later when demand exists.

### 3. Should SkillRegistry be a struct or actor?

Discovery involves filesystem I/O. Registration mutates state.

Decision: `struct` with mutating methods. Discovery and registration happen at setup time (before any async agent work). The registry is passed to Agent at init (which copies it since Agent is an actor). No concurrent access concerns.

### 4. How to handle skill instructions that reference files?

A skill's instructions might say `"Run scripts/analyze.py"` or `"See references/GUIDE.md"`. The agent needs to know the absolute path to these files.

Decision: `FileSkill` prepends a directory header to `instructions`:
```
[Skill: pdf | Directory: /Users/alice/.yrden/skills/pdf]
```

The agent (LLM) reads this header and resolves relative paths. This is the same approach Codex uses — include the path, let the LLM figure it out. No automatic path rewriting in skill instructions.

For code-based skills, the skill author controls paths directly (they're writing Swift code, they know their paths).

### 5. What about skills that need system dependencies?

Real skills often need Python, Node.js, npm packages, LibreOffice, etc. The `compatibility` field is supposed to declare these:
```yaml
compatibility: Requires python3, pypdf, pdfplumber. Install: pip install pypdf pdfplumber
```

For v1: Store `compatibility` on FileSkill. The agent can read it and warn the user or attempt installation. We don't enforce or auto-install dependencies — that's the user's responsibility (same as Claude Code and Codex).

### 6. Should skills have a `Skill` protocol `skillDirectory` property?

Code-based skills don't have a filesystem directory. File-based skills do. Should the protocol expose this?

Decision: No. `skillDirectory` is a `FileSkill`-specific property, not a protocol requirement. Code-based skills don't need it. If an agent needs to check whether a skill is file-based, it can check `skill is FileSkill` and downcast.

---

## Future Work

### v2: Progressive Disclosure (SkillTool)
Only inject metadata at startup. Provide `SkillTool` meta-tool for on-demand activation. The LLM calls `activate_skill("pdf")` when needed, receives full instructions as tool result. Critical for agents with 10+ skills. See Decision 5 for design sketch.

### v2: String Substitution ($ARGUMENTS)
Claude Code supports `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N` in SKILL.md. Enables parameterized skills:
```markdown
Fix the bug in $0 by applying the pattern described in references/patterns.md
```
Implementation: Before injecting instructions, replace `$ARGUMENTS` with the arguments string. Simple string replacement, ~20 lines.

### v2: Dynamic Context Injection (`` !`command` ``)
Claude Code supports `` !`command` `` syntax — executes shell command before skill content is sent, inserts stdout:
```markdown
Current git status: !`git status --short`
Recent commits: !`git log --oneline -5`
```
Implementation: Regex match `` !`...` `` patterns, execute via ShellTool, replace with output. Requires ShellTool at skill load time (not just at agent execution time).

### v3: Skill-Scoped Tool Restrictions
Enforce `allowed-tools` — when a skill is active, only specified tools can be invoked. Requires tracking "active skill" state in the agent loop and modifying the beforeTools approval phase.

### v3: Subagent Isolation (context: fork)
Run skill in isolated agent context (like Claude Code's `context: fork`). The skill's instructions become the subagent's prompt. Results are summarized and returned to the main conversation. Requires the multi-agent / subagent architecture.

### v3: Remote Skill Installation
Download skills from URLs or registries. Codex has `$skill-installer` that downloads GitHub repos as ZIP. Implementation: fetch archive, extract, validate SKILL.md, install to `~/.yrden/skills/`. Security: validate skill before loading, sandbox script execution.

### Future: Skill Lifecycle Hooks
`willActivate()`, `didDeactivate()` for skills that need setup/teardown (e.g., starting an MCP server, installing dependencies).

### Future: Skill Composition
Skills that depend on or extend other skills. The `theme-factory` skill, for example, is designed to work alongside `pptx`, `docx`, etc.

### Future: Hot Reload
File watchers detect changes to SKILL.md files and re-index without session restart. Claude Code and Codex both support this.

---

## References

### Agent Skills Standard
- [Agent Skills Specification](https://agentskills.io/specification)
- [Agent Skills — What Are Skills](https://agentskills.io/what-are-skills)
- [Agent Skills — Integrate Skills](https://agentskills.io/integrate-skills)
- [Agent Skills Reference SDK (GitHub)](https://github.com/agentskills/agentskills) — 9.2K stars, Python, Apache 2.0
- [Anthropic Skills Catalog (GitHub)](https://github.com/anthropics/skills) — 65K stars, Apache 2.0

### Agent Implementations
- [Claude Code Skills Documentation](https://code.claude.com/docs/en/skills)
- [Claude Code Subagents Documentation](https://code.claude.com/docs/en/sub-agents)
- [Agent Skills Best Practices (Anthropic Platform)](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Agent Skills Overview (Anthropic Platform)](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview)
- [OpenAI Codex Skills Documentation](https://developers.openai.com/codex/skills)
- [OpenAI Codex Create a Skill](https://developers.openai.com/codex/skills/create-skill/)
- [OpenAI Skills Catalog (GitHub)](https://github.com/openai/skills)
- [Codex Skills Rust Implementation](https://github.com/openai/codex/tree/main/codex-rs/core/src/skills) — loader.rs, render.rs, injection.rs, manager.rs
- [Cursor Agent Skills Documentation](https://cursor.com/docs/context/skills)

### Implementation Deep Dives
- [Claude Agent Skills: A First Principles Deep Dive](https://leehanchung.github.io/blogs/2025/10/26/claude-skills-deep-dive/)
- [DeepWiki: Claude Code Skill System](https://deepwiki.com/anthropics/claude-code/3.7-custom-slash-commands)
- [Anthropic Engineering: Equipping Agents with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [Skills in OpenAI Codex (Jesse Vincent)](https://blog.fsck.com/2025/12/19/codex-skills/)
- [Porting Skills to OpenAI Codex (Jesse Vincent)](https://blog.fsck.com/2025/10/27/skills-for-openai-codex/)
- [Testing Agent Skills with Evals (OpenAI)](https://developers.openai.com/blog/eval-skills/)

### Alternative Skills Models
- [Microsoft Semantic Kernel Plugins](https://learn.microsoft.com/en-us/semantic-kernel/concepts/plugins/)
- [LangChain Skills Documentation](https://docs.langchain.com/oss/python/langchain/multi-agent/skills)
- [LangChain Blog: Using Skills with Deep Agents](https://blog.langchain.com/using-skills-with-deep-agents/)
- [CrewAI Agents Documentation](https://docs.crewai.com/en/concepts/agents)

### Analysis
- [Simon Willison on Agent Skills](https://simonwillison.net/2025/Dec/19/agent-skills/)
- [Simon Willison: OpenAI Quietly Adopting Skills](https://simonwillison.net/2025/Dec/12/openai-skills/)
- [Arcade.dev: Skills vs Tools for AI Agents](https://blog.arcade.dev/what-are-agent-skills-and-tools)
- [Unite.AI: Anthropic Opens Agent Skills Standard](https://www.unite.ai/anthropic-opens-agent-skills-standard-continuing-its-pattern-of-building-industry-infrastructure/)

### Community Skill Collections
- [alirezarezvani/claude-skills](https://github.com/alirezarezvani/claude-skills) — 48 production-ready skills
- [levnikolaevich/claude-code-skills](https://github.com/levnikolaevich/claude-code-skills) — Full delivery workflow skills
- [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) — Curated list
- [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) — 200+ cross-platform skills

### Swift Ecosystem
- [SwiftWasm Skills (GitHub)](https://github.com/swiftwasm/skills) — SKILL.md files for SwiftWasm, not a framework
