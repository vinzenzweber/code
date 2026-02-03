# Auto-Dev Refactoring Guide

This document captures research and architectural decisions for rewriting the `code.sh` bash script (~2200 lines) to a more robust, maintainable solution.

---

## Table of Contents

1. [Current Implementation Analysis](#current-implementation-analysis)
2. [Language Options Comparison](#language-options-comparison)
3. [Recommendation: TypeScript](#recommendation-typescript)
4. [TypeScript Architecture](#typescript-architecture)
5. [Library Research & Recommendations](#library-research--recommendations)
6. [Code Examples](#code-examples)
7. [Build & Distribution](#build--distribution)
8. [Migration Strategy](#migration-strategy)
9. [References](#references)

---

## Current Implementation Analysis

### What `code.sh` Does

The bash script orchestrates automated feature development through multiple Claude Code sessions:

| Session | Phase | Context | Purpose |
|---------|-------|---------|---------|
| 0 | User Feedback Triage | Clean | Triage `user-feedback` issues; create/link child issues; close/epic/clarify |
| 1 | Issue Selection | Clean | Analyze and select GitHub issues |
| 2 | Planning | Clean | Explore codebase, create implementation plan |
| 3 | Implementation + Testing + PR | Shared | Code, test, create PR (tight feedback loop) |
| - | CI Fix Loop | N/A | Retry CI failures (bounded attempts) |
| 4 | Code Review | Clean | Fresh-eyes review without implementation bias |
| 5 | Fix Review Feedback | Clean | Address review comments |
| 7 | Documentation (Optional) | Clean | Check/update CLAUDE.md before merge if needed |
| 6 | Merge & Deploy + Verify | Shared | Merge PR, verify production |

Note: In the current script flow, documentation checks (Session 7) run after review approval but before merge/deploy.

### Current Features

- **GitHub-based Memory System**: Labels for phase tracking, comments for session data
- **Crash Recovery**: Resume from any phase after interruption
- **Multi-machine Support**: All state stored in GitHub (start on laptop, continue on desktop)
- **Cost Tracking**: Accumulated costs tracked per issue via session comments
- **Audit Trail**: Structured comments document every session
- **Issue Discovery**: Automatically creates issues for bugs/tech debt found during work
- **Pause/Resume**: ESC key pauses execution, any key resumes

### Pain Points with Bash

| Issue | Impact |
|-------|--------|
| No type safety | Runtime errors from typos, wrong variable types |
| Complex string parsing | JSON parsing via `jq` is fragile |
| Error handling | `set -e` + traps are blunt instruments |
| Testing | Extremely difficult to unit test |
| IDE support | Limited autocomplete, no refactoring tools |
| State management | Implicit in function calls, easy to lose track |
| Debugging | `echo` statements, no debugger |
| Cross-platform | Bash version differences, macOS vs Linux |

---

## Language Options Comparison

### 1. TypeScript (Recommended)

**Pros:**
- Claude Code itself is TypeScript - can leverage its patterns
- Anthropic has official TypeScript SDK (`@anthropic-ai/sdk`)
- Strong typing catches errors at compile time
- Native async/await for cleaner concurrent operations
- Rich ecosystem (Octokit for GitHub, Zod for validation)
- Can compile to single executable with `bun build --compile`
- Excellent IDE support (VSCode, WebStorm)
- Easy to test with Vitest/Jest

**Cons:**
- Requires Node.js/Bun runtime (unless compiled)
- More verbose than bash for simple shell commands
- ~50-100MB binary size when compiled

**Best for:** Maximum type safety, integration with Claude Code patterns, long-term maintainability.

### 2. Anthropic Agent SDK (Python)

**Pros:**
- Purpose-built for multi-step agent workflows
- Built-in tool definition, conversation management, streaming
- Handles the "agentic loop" pattern the script implements manually
- Official Anthropic support and documentation
- Good async support with `asyncio`

**Cons:**
- Python runtime required everywhere
- Less direct shell integration than bash
- May be overkill if orchestrating Claude Code CLI (vs direct API calls)
- Dependency management (virtualenvs, pip)

**Best for:** Replacing Claude Code CLI calls with direct API calls, complex agent behaviors.

### 3. Python (Standard)

**Pros:**
- Anthropic's official Python SDK
- Simple subprocess handling with `subprocess` module
- Good async support with `asyncio`
- Easy to prototype quickly
- Rich GitHub integration (`PyGithub`)

**Cons:**
- Dynamic typing means runtime errors possible
- Python version/dependency management complexity
- No single-binary deployment without PyInstaller/Nuitka
- Slower startup than compiled languages

**Best for:** Quick iteration, data processing, scripting.

### 4. Rust

**Pros:**
- Single binary with zero runtime dependencies
- Excellent error handling with `Result<T, E>` type
- Great CLI frameworks (`clap`, `indicatif`)
- Memory safety guarantees
- Best performance characteristics
- Small binary size (few MB)

**Cons:**
- Steeper learning curve
- More verbose for string manipulation
- Anthropic SDK is community-maintained, not official
- Longer compile times
- Overkill for orchestration scripts

**Best for:** Performance-critical tools, wide distribution, embedded systems.

### 5. Go

**Pros:**
- Single binary compilation
- Simple concurrency with goroutines
- Fast compilation
- Good CLI ecosystem (`cobra`, `viper`)
- Small binary size

**Cons:**
- No official Anthropic SDK (community only)
- Verbose error handling (`if err != nil`)
- Less expressive type system than TypeScript/Rust
- No generics until recently (ecosystem still catching up)

**Best for:** Simple, portable CLI tools with good concurrency needs.

### Comparison Matrix

| Criterion | TypeScript | Agent SDK | Python | Rust | Go |
|-----------|------------|-----------|--------|------|-----|
| Type Safety | ★★★★★ | ★★☆☆☆ | ★★☆☆☆ | ★★★★★ | ★★★★☆ |
| Anthropic SDK | Official | Official | Official | Community | Community |
| Learning Curve | Low | Low | Low | High | Medium |
| Binary Distribution | ★★★☆☆ | ★★☆☆☆ | ★★☆☆☆ | ★★★★★ | ★★★★★ |
| Ecosystem | ★★★★★ | ★★★★☆ | ★★★★★ | ★★★☆☆ | ★★★★☆ |
| Testing | ★★★★★ | ★★★★☆ | ★★★★☆ | ★★★★★ | ★★★★☆ |
| Shell Integration | ★★★★☆ | ★★★☆☆ | ★★★★☆ | ★★★★☆ | ★★★★☆ |
| IDE Support | ★★★★★ | ★★★★☆ | ★★★★☆ | ★★★★☆ | ★★★★☆ |

---

## Recommendation: TypeScript

TypeScript is recommended for this rewrite because:

1. **Alignment with Claude Code** - The tool you're orchestrating is itself TypeScript; you can study its patterns and potentially reuse code
2. **Type Safety** - The complex state machine (phases, metadata, session history) benefits enormously from typed interfaces
3. **Better Error Handling** - Try/catch with typed errors vs bash's trap handlers
4. **Cleaner Async** - CI polling, parallel operations, streaming all become cleaner
5. **Testable** - Unit test individual functions, mock GitHub API
6. **Single Binary Option** - Bun can compile to standalone executable

---

## TypeScript Architecture

### Project Structure

```
auto-dev/
├── src/
│   ├── index.ts                 # CLI entry point
│   ├── cli/
│   │   ├── commands/
│   │   │   ├── run.ts           # Main continuous loop (default command)
│   │   │   ├── status.ts        # --status command
│   │   │   ├── init.ts          # --init command
│   │   │   └── index.ts         # Command exports
│   │   └── cli.ts               # Clipanion CLI setup
│   ├── workflow/
│   │   ├── machine.ts           # XState state machine definition
│   │   ├── phases/
│   │   │   ├── select.ts        # Session 1: Issue selection
│   │   │   ├── plan.ts          # Session 2: Planning
│   │   │   ├── implement.ts     # Session 3: Implementation + Testing + PR
│   │   │   ├── ci.ts            # CI wait (not a Claude session)
│   │   │   ├── review.ts        # Session 4: Code review
│   │   │   ├── fix.ts           # Session 5: Fix feedback
│   │   │   ├── merge.ts         # Session 6: Merge & deploy
│   │   │   ├── docs.ts          # Session 7: Documentation
│   │   │   └── index.ts         # Phase exports
│   │   └── orchestrator.ts      # Main workflow coordinator
│   ├── github/
│   │   ├── client.ts            # Octokit wrapper with retry logic
│   │   ├── labels.ts            # Phase label management (ensure, set, get)
│   │   ├── memory.ts            # GitHub-based state persistence
│   │   ├── issues.ts            # Issue operations (list, get, close)
│   │   ├── prs.ts               # PR operations (create, merge, checks)
│   │   └── types.ts             # GitHub API response types
│   ├── claude/
│   │   ├── session.ts           # Claude CLI wrapper (spawn, stream, kill)
│   │   ├── stream-parser.ts     # Streaming JSON output parser
│   │   └── prompts/
│   │       ├── select.ts        # Issue selection prompt
│   │       ├── plan.ts          # Planning prompt
│   │       ├── implement.ts     # Implementation prompt
│   │       ├── review.ts        # Code review prompt
│   │       ├── fix.ts           # Fix feedback prompt
│   │       ├── merge.ts         # Merge & verify prompt
│   │       ├── docs.ts          # Documentation prompt
│   │       └── shared.ts        # Shared prompt fragments (NEW_ISSUE_INSTRUCTIONS)
│   ├── process/
│   │   ├── spawn.ts             # Child process management utilities
│   │   ├── cleanup.ts           # Background process cleanup (port 3000, node)
│   │   └── signals.ts           # Graceful shutdown handlers (SIGTERM, SIGINT)
│   ├── config/
│   │   ├── schema.ts            # Zod configuration schema
│   │   └── loader.ts            # Config loading (env, files, defaults)
│   ├── logger/
│   │   ├── index.ts             # Pino logger setup
│   │   └── formatters.ts        # Custom log formatters (colors, progress)
│   └── types/
│       ├── workflow.ts          # Workflow state types (Phase, Context)
│       ├── issue.ts             # Issue/PR types
│       ├── session.ts           # Claude session types
│       └── config.ts            # Re-export config types
├── tests/
│   ├── workflow/
│   │   ├── machine.test.ts      # State machine transition tests
│   │   └── orchestrator.test.ts # Integration tests
│   ├── github/
│   │   ├── memory.test.ts       # GitHub memory layer tests
│   │   └── labels.test.ts       # Label management tests
│   ├── claude/
│   │   └── stream-parser.test.ts # Stream parser tests
│   └── fixtures/
│       ├── issues.json          # Sample issue data
│       ├── stream-output.jsonl  # Sample Claude output
│       └── github-responses/    # Mocked GitHub API responses
├── package.json
├── tsconfig.json
├── vitest.config.ts
├── .env.example
└── README.md
```

### Layer Responsibilities

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLI Layer                                │
│  • Parse arguments (--once, --issue, --resume, --status, etc.)  │
│  • Setup signal handlers                                        │
│  • Initialize logger                                            │
│  • Load configuration                                           │
│  • Invoke orchestrator                                          │
└─────────────────────────────┬───────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────┐
│                    Workflow Orchestrator                        │
│  • Manage XState interpreter                                    │
│  • Coordinate phase transitions                                 │
│  • Handle resume logic                                          │
│  • Main loop (continuous/single cycle)                          │
└─────────────────────────────┬───────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────┐
│                    State Machine (XState)                       │
│  • Define valid states and transitions                          │
│  • Guard conditions (e.g., max review rounds)                   │
│  • Invoke async services (phase functions)                      │
│  • Maintain workflow context                                    │
└─────────────────────────────┬───────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  Phase Functions│ │  Claude Session │ │  GitHub Memory  │
│  • select()     │ │  • spawn()      │ │  • setPhase()   │
│  • plan()       │ │  • stream()     │ │  • getPhase()   │
│  • implement()  │ │  • parse()      │ │  • setMetadata()│
│  • review()     │ │  • kill()       │ │  • postSession()│
│  • fix()        │ │                 │ │  • getPlan()    │
│  • merge()      │ │                 │ │                 │
│  • docs()       │ │                 │ │                 │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

### Core Type Definitions

```typescript
// src/types/workflow.ts

/**
 * All possible workflow phases.
 * Maps directly to GitHub labels: auto-dev:<phase>
 */
export type Phase =
  | 'selecting'     // Being analyzed for selection
  | 'planning'      // Creating implementation plan
  | 'implementing'  // Writing code and testing
  | 'pr-waiting'    // PR created, waiting for CI
  | 'reviewing'     // Under code review
  | 'fixing'        // Addressing review feedback
  | 'merging'       // Being merged and deployed
  | 'verifying'     // Production verification
  | 'complete'      // Successfully completed
  | 'blocked'       // Needs manual intervention
  | 'ci-failed';    // CI checks failing

/**
 * GitHub issue context needed for workflow
 */
export interface IssueContext {
  number: number;
  title: string;
  body: string;
  labels: string[];
}

/**
 * Workflow context maintained by XState
 * This is the "memory" that persists across phase transitions
 */
export interface WorkflowContext {
  issue: IssueContext | null;
  prNumber: number | null;
  branchName: string | null;
  reviewRound: number;
  accumulatedCost: number;
  sessionHistory: SessionRecord[];
  blockReason?: string;
}

/**
 * Record of a single Claude session
 * Posted as structured comment to GitHub issue
 */
export interface SessionRecord {
  id: string;           // Unique identifier: session-<timestamp>-<pid>
  phase: Phase;         // Which phase this session executed
  startTime: Date;
  endTime: Date;
  cost: number;         // USD cost from Claude API
  summary: string;      // Human-readable summary
  details?: string;     // Optional additional details
}

/**
 * Metadata stored in GitHub labels
 * Pattern: auto-dev:<key>:<value>
 */
export interface WorkflowMetadata {
  pr?: number;      // auto-dev:pr:47
  branch?: string;  // auto-dev:branch:feat/issue-47
  round?: number;   // auto-dev:round:2
  cost?: number;    // auto-dev:cost:1.23
}

/**
 * Events that trigger state machine transitions
 */
export type WorkflowEvent =
  | { type: 'ISSUE_SELECTED'; issue: IssueContext }
  | { type: 'PLAN_COMPLETE' }
  | { type: 'IMPLEMENTATION_COMPLETE'; prNumber: number; branch: string }
  | { type: 'CI_PASSED' }
  | { type: 'CI_FAILED' }
  | { type: 'REVIEW_APPROVED' }
  | { type: 'CHANGES_REQUESTED' }
  | { type: 'FIXES_PUSHED' }
  | { type: 'MERGE_COMPLETE' }
  | { type: 'VERIFICATION_COMPLETE' }
  | { type: 'BLOCKED'; reason: string }
  | { type: 'RESUME'; phase: Phase; context: Partial<WorkflowContext> };
```

### State Machine Definition

```typescript
// src/workflow/machine.ts

import { createMachine, assign } from 'xstate';
import type { Phase, WorkflowContext, WorkflowEvent, IssueContext } from '../types/workflow';

/**
 * XState machine defining the auto-dev workflow.
 *
 * Key design decisions:
 * - Each state invokes an async service (the phase function)
 * - Context stores workflow state (issue, PR, review round, etc.)
 * - Guards prevent invalid transitions (e.g., too many review rounds)
 * - The 'resuming' state handles crash recovery
 */
export const workflowMachine = createMachine({
  id: 'autodev',
  initial: 'idle',

  // Type definitions for context and events
  types: {} as {
    context: WorkflowContext;
    events: WorkflowEvent;
  },

  // Initial context
  context: {
    issue: null,
    prNumber: null,
    branchName: null,
    reviewRound: 0,
    accumulatedCost: 0,
    sessionHistory: [],
  },

  states: {
    /**
     * Idle state - waiting for issue selection or resume
     */
    idle: {
      on: {
        ISSUE_SELECTED: {
          target: 'selecting',
          actions: assign({ issue: ({ event }) => event.issue }),
        },
        RESUME: {
          target: 'resuming',
        },
      },
    },

    /**
     * Resuming state - routes to correct phase based on GitHub state
     * Uses 'always' transitions (transient) to immediately redirect
     */
    resuming: {
      always: [
        { target: 'selecting', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'selecting' },
        { target: 'planning', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'planning' },
        { target: 'implementing', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'implementing' },
        { target: 'prWaiting', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'pr-waiting' },
        { target: 'reviewing', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'reviewing' },
        { target: 'fixing', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'fixing' },
        { target: 'merging', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'merging' },
        { target: 'verifying', guard: ({ event }) => event.type === 'RESUME' && event.phase === 'verifying' },
        { target: 'idle' }, // Fallback
      ],
    },

    /**
     * Session 1: Issue Selection
     * Context: Clean (fresh perspective for decision-making)
     */
    selecting: {
      invoke: {
        src: 'selectIssue',
        onDone: {
          target: 'planning',
          actions: assign({ issue: ({ event }) => event.output }),
        },
        onError: 'idle', // No issues found, return to idle
      },
    },

    /**
     * Session 2: Planning
     * Context: Clean (fresh codebase exploration)
     * Output: Implementation plan posted to GitHub issue
     */
    planning: {
      invoke: {
        src: 'planImplementation',
        onDone: 'implementing',
        onError: {
          target: 'blocked',
          actions: assign({ blockReason: 'Planning failed' }),
        },
      },
    },

    /**
     * Session 3: Implementation + Testing + PR Creation
     * Context: Shared (tight feedback loop for implement/test/fix)
     */
    implementing: {
      invoke: {
        src: 'implementAndTest',
        onDone: {
          target: 'prWaiting',
          actions: assign({
            prNumber: ({ event }) => event.output.prNumber,
            branchName: ({ event }) => event.output.branch,
          }),
        },
        onError: {
          target: 'blocked',
          actions: assign({ blockReason: 'Implementation failed' }),
        },
      },
    },

    /**
     * CI Wait (not a Claude session)
     * Polls GitHub Actions status
     */
    prWaiting: {
      invoke: {
        src: 'waitForCI',
        onDone: 'reviewing',
        onError: 'ciFailed',
      },
    },

    /**
     * Session 4: Code Review
     * Context: CLEAN (critical for quality - no implementation bias)
     */
    reviewing: {
      entry: assign({ reviewRound: ({ context }) => context.reviewRound + 1 }),
      invoke: {
        src: 'reviewCode',
        onDone: [
          {
            target: 'merging',
            guard: ({ event }) => event.output.approved,
          },
          { target: 'fixing' }, // Changes requested
        ],
        onError: {
          target: 'blocked',
          actions: assign({ blockReason: 'Code review failed' }),
        },
      },
    },

    /**
     * Session 5: Fix Review Feedback
     * Context: Clean (address specific comments without defensive bias)
     */
    fixing: {
      // Guard: fail if too many review rounds
      always: {
        target: 'blocked',
        guard: ({ context }) => context.reviewRound >= 10,
        actions: assign({ blockReason: 'Max review rounds (10) reached' }),
      },
      invoke: {
        src: 'fixReviewFeedback',
        onDone: 'prWaiting', // Back to CI
        onError: {
          target: 'blocked',
          actions: assign({ blockReason: 'Fix feedback failed' }),
        },
      },
    },

    /**
     * Session 6: Merge + Deploy + Verify
     * Context: Shared (sequential dependent steps)
     */
    merging: {
      invoke: {
        src: 'mergeAndVerify',
        onDone: 'verifying',
        onError: {
          target: 'blocked',
          actions: assign({ blockReason: 'Merge/deploy failed' }),
        },
      },
    },

    /**
     * Session 7: Documentation (optional)
     * Context: Clean (focused on docs)
     */
    verifying: {
      invoke: {
        src: 'updateDocumentation',
        onDone: 'complete',
        onError: 'complete', // Docs are optional, don't block
      },
    },

    /**
     * Final state: Success
     */
    complete: {
      type: 'final',
      entry: 'onComplete', // Action to close issue, post summary
    },

    /**
     * Error state: Blocked
     * Requires manual intervention, then RESUME event
     */
    blocked: {
      entry: 'onBlocked', // Action to add blocked label, post reason
      on: {
        RESUME: 'resuming',
      },
    },

    /**
     * Error state: CI Failed
     * Can retry from here
     */
    ciFailed: {
      entry: 'onCIFailed',
      on: {
        RESUME: 'prWaiting',
      },
    },
  },
});
```

---

## Library Research & Recommendations

### CLI Framework: Clipanion

**Why Clipanion over Commander/Yargs:**
- TypeScript-first design with true type safety
- Class-based command structure
- Zero dependencies
- Built-in validation
- Powers Yarn Modern (battle-tested)

**Alternatives considered:**
- **Commander.js**: Industry standard, but TypeScript bolted on top
- **Yargs**: Fluent API, but requires manual TS configuration
- **oclif**: Full framework with plugins, overkill for this use case

```typescript
// Example Clipanion command
import { Command, Option } from 'clipanion';

export class RunCommand extends Command {
  static paths = [Command.Default];

  once = Option.Boolean('--once', false, {
    description: 'Run single cycle then exit',
  });

  issue = Option.String('-i,--issue', {
    description: 'Work on specific issue number',
  });

  async execute(): Promise<number> {
    // Implementation
    return 0;
  }
}
```

### State Machine: XState

**Why XState:**
- Explicit state definitions (matches our phase system)
- Visualizer for debugging (stately.ai/viz)
- Built-in async service invocation
- Guards for transition conditions
- Well-documented with TypeScript support

**Alternatives considered:**
- **TS-FSM**: Lightweight, but less ecosystem
- **Fiume**: Zero-dependency, but less mature
- **Custom implementation**: More control, but reinventing the wheel

### GitHub API: Octokit

**Why Octokit:**
- Official GitHub SDK
- Full TypeScript types
- Built-in pagination
- Retry logic available
- REST and GraphQL support

```typescript
import { Octokit } from '@octokit/rest';

const octokit = new Octokit({ auth: process.env.GITHUB_TOKEN });

// Typed response
const { data: issue } = await octokit.issues.get({
  owner: 'user',
  repo: 'repo',
  issue_number: 42,
});
```

### Logging: Pino

**Why Pino over Winston:**
- 5-10x faster (important for streaming logs)
- Structured JSON by default
- Low overhead for high-frequency logging
- Built-in pretty-printing for development

**Configuration:**

```typescript
import pino from 'pino';

export const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: process.env.NODE_ENV === 'development'
    ? { target: 'pino-pretty' }
    : undefined,
});
```

### Configuration: Zod + Cosmiconfig

**Why this combination:**
- **Zod**: Runtime validation with TypeScript inference
- **Cosmiconfig**: Searches multiple config sources (env, files, package.json)
- Fail-fast on invalid configuration

```typescript
import { z } from 'zod';

export const ConfigSchema = z.object({
  GITHUB_TOKEN: z.string().min(1, 'GitHub token required'),
  GITHUB_OWNER: z.string().min(1),
  GITHUB_REPO: z.string().min(1),
  MAX_REVIEW_ROUNDS: z.coerce.number().int().positive().default(10),
  CI_POLL_INTERVAL_MS: z.coerce.number().default(30_000),
  CI_MAX_WAIT_MS: z.coerce.number().default(900_000),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Config = z.infer<typeof ConfigSchema>;
```

### Process Management

**Child process spawning:**
- Use `spawn()` over `exec()` for streaming output
- Track PIDs for cleanup on shutdown
- Implement timeout handling

**Graceful shutdown:**
- Listen for SIGTERM and SIGINT
- Kill tracked child processes
- Clean up port 3000 (dev servers)
- Wait for in-flight work before exit

### Summary Table

| Category | Recommended | Alternative | Rationale |
|----------|-------------|-------------|-----------|
| CLI Framework | Clipanion | Commander | TypeScript-first, class-based |
| State Machine | XState | TS-FSM | Explicit states, visualizer, guards |
| GitHub API | Octokit | graphql-request | Official SDK, full types |
| Logging | Pino | Winston | Performance, structured JSON |
| Config | Zod + Cosmiconfig | Dotenv only | Type-safe, multi-source |
| Process | Node spawn() | Execa | Built-in, streaming support |
| Testing | Vitest | Jest | Faster, native ESM support |
| Build | tsup | esbuild | DTS generation, simple config |

---

## Code Examples

### Claude Session Runner

```typescript
// src/claude/session.ts

import { spawn, ChildProcess } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { logger } from '../logger';
import { StreamParser, ParsedEvent } from './stream-parser';

export interface SessionOptions {
  prompt: string;
  cwd?: string;
  timeout?: number; // Default: 10 minutes
}

export interface SessionResult {
  success: boolean;
  output: string;
  cost: number;
  duration: number;
}

/**
 * Wrapper for Claude CLI sessions.
 *
 * Spawns claude with streaming JSON output and parses events
 * for real-time progress display.
 */
export class ClaudeSession extends EventEmitter {
  private process: ChildProcess | null = null;
  private parser: StreamParser;
  private startTime: number = 0;

  constructor() {
    super();
    this.parser = new StreamParser();
  }

  /**
   * Run a Claude session with the given prompt.
   *
   * @param options - Session configuration
   * @returns Promise resolving to session result
   */
  async run(options: SessionOptions): Promise<SessionResult> {
    const { prompt, cwd = process.cwd(), timeout = 600_000 } = options;

    this.startTime = Date.now();
    let output = '';
    let cost = 0;

    return new Promise((resolve, reject) => {
      // Spawn Claude CLI with streaming JSON output
      this.process = spawn(
        'claude',
        [
          '--dangerously-skip-permissions',
          '--model', 'opus',
          '--verbose',
          '-p', // Print mode (non-interactive)
          '--output-format', 'stream-json',
          prompt,
        ],
        {
          cwd,
          stdio: ['ignore', 'pipe', 'pipe'],
          env: { ...process.env },
        }
      );

      // Setup timeout
      const timeoutId = setTimeout(() => {
        this.kill();
        reject(new Error(`Session timed out after ${timeout}ms`));
      }, timeout);

      // Parse streaming stdout
      this.process.stdout?.on('data', (chunk: Buffer) => {
        const lines = chunk.toString().split('\n').filter(Boolean);

        for (const line of lines) {
          try {
            const event = this.parser.parse(line);
            if (event) {
              this.handleEvent(event);
              if (event.type === 'result') {
                output = event.content || '';
                cost = event.cost || 0;
              }
            }
          } catch {
            // Skip non-JSON lines
          }
        }
      });

      // Log stderr (debug info from Claude)
      this.process.stderr?.on('data', (chunk: Buffer) => {
        logger.debug({ stderr: chunk.toString() }, 'Claude stderr');
      });

      // Handle process exit
      this.process.on('close', (code) => {
        clearTimeout(timeoutId);
        const duration = Date.now() - this.startTime;

        resolve({
          success: code === 0,
          output,
          cost,
          duration,
        });
      });

      this.process.on('error', (err) => {
        clearTimeout(timeoutId);
        reject(err);
      });
    });
  }

  /**
   * Handle parsed streaming events.
   * Emits events for progress display.
   */
  private handleEvent(event: ParsedEvent): void {
    switch (event.type) {
      case 'text':
        this.emit('text', event.content);
        logger.info({ text: event.content?.slice(0, 100) }, 'Claude response');
        break;

      case 'tool_use':
        this.emit('tool', event.tool);
        logger.info(
          { tool: event.tool?.name, input: event.tool?.input?.slice(0, 80) },
          'Tool call'
        );
        break;

      case 'tool_result':
        this.emit('tool_result', event.result);
        const status = event.result?.error ? '✗' : '✓';
        logger.info({ status, tool: event.result?.tool }, 'Tool result');
        break;
    }
  }

  /**
   * Kill the running process.
   */
  kill(): void {
    if (this.process && !this.process.killed) {
      this.process.kill('SIGTERM');
    }
  }
}
```

### Streaming JSON Parser

```typescript
// src/claude/stream-parser.ts

/**
 * Parsed event from Claude's streaming JSON output.
 */
export interface ParsedEvent {
  type: 'text' | 'tool_use' | 'tool_result' | 'result' | 'unknown';
  content?: string;
  tool?: { id: string; name: string; input: string };
  result?: { tool: string; error: boolean; content: string };
  cost?: number;
}

/**
 * Parser for Claude's stream-json output format.
 *
 * Handles the following event types:
 * - assistant: Contains text responses and tool_use blocks
 * - user: Contains tool_result blocks
 * - result: Final result with cost information
 */
export class StreamParser {
  // Map tool IDs to names for result correlation
  private toolNames = new Map<string, string>();

  /**
   * Parse a single line of streaming JSON.
   *
   * @param line - Raw line from stdout
   * @returns Parsed event or null if not valid JSON
   */
  parse(line: string): ParsedEvent | null {
    if (!line.startsWith('{')) return null;

    try {
      const data = JSON.parse(line);
      return this.parseEvent(data);
    } catch {
      return null;
    }
  }

  private parseEvent(data: any): ParsedEvent | null {
    const type = data.type;

    if (type === 'assistant') {
      // Check for text content
      const textBlock = data.message?.content?.find(
        (c: any) => c.type === 'text'
      );
      if (textBlock?.text) {
        return { type: 'text', content: textBlock.text };
      }

      // Check for tool use
      const toolBlock = data.message?.content?.find(
        (c: any) => c.type === 'tool_use'
      );
      if (toolBlock) {
        const input = this.extractToolInput(toolBlock.input);
        this.toolNames.set(toolBlock.id, toolBlock.name);
        return {
          type: 'tool_use',
          tool: { id: toolBlock.id, name: toolBlock.name, input },
        };
      }
    }

    if (type === 'user') {
      // Tool result
      const resultBlock = data.message?.content?.find(
        (c: any) => c.type === 'tool_result'
      );
      if (resultBlock) {
        const toolName = this.toolNames.get(resultBlock.tool_use_id) || 'Tool';
        return {
          type: 'tool_result',
          result: {
            tool: toolName,
            error: resultBlock.is_error || false,
            content: this.extractResultContent(resultBlock.content),
          },
        };
      }
    }

    if (type === 'result') {
      return {
        type: 'result',
        content: data.result,
        cost: data.total_cost_usd,
      };
    }

    return null;
  }

  private extractToolInput(input: any): string {
    if (!input) return 'working...';
    return (
      input.description ||
      input.command ||
      input.pattern ||
      input.query ||
      input.file_path ||
      input.prompt ||
      'working...'
    ).slice(0, 100);
  }

  private extractResultContent(content: any): string {
    if (typeof content === 'string') return content.slice(0, 200);
    if (Array.isArray(content)) {
      return (content[0]?.text || content[0]?.content || '').slice(0, 200);
    }
    return '';
  }
}
```

### GitHub Memory Layer

```typescript
// src/github/memory.ts

import { Octokit } from '@octokit/rest';
import type { Phase, WorkflowMetadata, SessionRecord } from '../types/workflow';
import { logger } from '../logger';

const PLAN_START_MARKER = '<!-- AUTODEV-PLAN-START -->';
const PLAN_END_MARKER = '<!-- AUTODEV-PLAN-END -->';

/**
 * GitHub-based persistence layer.
 *
 * Uses GitHub labels for phase tracking and comments for session memory.
 * This enables:
 * - Crash recovery (state survives process restarts)
 * - Multi-machine support (state visible from any machine)
 * - Audit trail (all actions documented in issue)
 */
export class GitHubMemory {
  private octokit: Octokit;
  private owner: string;
  private repo: string;

  constructor(token: string, owner: string, repo: string) {
    this.octokit = new Octokit({ auth: token });
    this.owner = owner;
    this.repo = repo;
  }

  // ─────────────────────────────────────────────────────────────────
  // Phase Management (Labels)
  // ─────────────────────────────────────────────────────────────────

  /**
   * Set the workflow phase for an issue.
   * Removes existing phase labels and adds the new one.
   */
  async setPhase(issueNumber: number, phase: Phase): Promise<void> {
    const { data: issue } = await this.octokit.issues.get({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
    });

    // Remove existing phase labels
    const existingPhaseLabels = issue.labels
      .map((l) => (typeof l === 'string' ? l : l.name))
      .filter((name): name is string =>
        name?.startsWith('auto-dev:') && this.isPhaseLabel(name)
      );

    for (const label of existingPhaseLabels) {
      await this.octokit.issues
        .removeLabel({
          owner: this.owner,
          repo: this.repo,
          issue_number: issueNumber,
          name: label,
        })
        .catch(() => {}); // Ignore if already removed
    }

    // Add new phase label
    await this.octokit.issues.addLabels({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
      labels: [`auto-dev:${phase}`],
    });

    logger.info({ issueNumber, phase }, 'Phase updated');
  }

  /**
   * Get the current phase of an issue.
   */
  async getPhase(issueNumber: number): Promise<Phase | null> {
    const { data: issue } = await this.octokit.issues.get({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
    });

    for (const label of issue.labels) {
      const name = typeof label === 'string' ? label : label.name;
      if (name?.startsWith('auto-dev:')) {
        const phase = name.replace('auto-dev:', '') as Phase;
        if (this.isPhaseLabel(`auto-dev:${phase}`)) {
          return phase;
        }
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────
  // Metadata Management (Labels)
  // ─────────────────────────────────────────────────────────────────

  /**
   * Set metadata for an issue (PR number, branch, round, cost).
   * Pattern: auto-dev:<key>:<value>
   */
  async setMetadata(
    issueNumber: number,
    key: keyof WorkflowMetadata,
    value: string | number
  ): Promise<void> {
    const labelName = `auto-dev:${key}:${value}`;

    // Remove existing metadata with same key
    const { data: issue } = await this.octokit.issues.get({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
    });

    const existingLabel = issue.labels.find((l) => {
      const name = typeof l === 'string' ? l : l.name;
      return name?.startsWith(`auto-dev:${key}:`);
    });

    if (existingLabel) {
      const name =
        typeof existingLabel === 'string' ? existingLabel : existingLabel.name;
      if (name) {
        await this.octokit.issues
          .removeLabel({
            owner: this.owner,
            repo: this.repo,
            issue_number: issueNumber,
            name,
          })
          .catch(() => {});
      }
    }

    // Ensure label exists (create if needed)
    await this.octokit.issues
      .createLabel({
        owner: this.owner,
        repo: this.repo,
        name: labelName,
        color: 'CCCCCC',
      })
      .catch(() => {}); // Ignore if exists

    // Add label to issue
    await this.octokit.issues.addLabels({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
      labels: [labelName],
    });
  }

  /**
   * Get all metadata for an issue.
   */
  async getMetadata(issueNumber: number): Promise<WorkflowMetadata> {
    const { data: issue } = await this.octokit.issues.get({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
    });

    const metadata: WorkflowMetadata = {};

    for (const label of issue.labels) {
      const name = typeof label === 'string' ? label : label.name;
      if (!name) continue;

      const prMatch = name.match(/^auto-dev:pr:(\d+)$/);
      if (prMatch) metadata.pr = parseInt(prMatch[1], 10);

      const branchMatch = name.match(/^auto-dev:branch:(.+)$/);
      if (branchMatch) metadata.branch = branchMatch[1];

      const roundMatch = name.match(/^auto-dev:round:(\d+)$/);
      if (roundMatch) metadata.round = parseInt(roundMatch[1], 10);

      const costMatch = name.match(/^auto-dev:cost:([\d.]+)$/);
      if (costMatch) metadata.cost = parseFloat(costMatch[1]);
    }

    return metadata;
  }

  // ─────────────────────────────────────────────────────────────────
  // Session Memory (Comments)
  // ─────────────────────────────────────────────────────────────────

  /**
   * Post a session record as a structured comment.
   */
  async postSessionMemory(
    issueNumber: number,
    session: SessionRecord
  ): Promise<void> {
    const durationMs = session.endTime.getTime() - session.startTime.getTime();
    const durationMin = Math.floor(durationMs / 60000);
    const durationSec = Math.floor((durationMs % 60000) / 1000);

    const body = `## 🤖 Auto-Dev Session: ${this.formatPhase(session.phase)}

| Field | Value |
|-------|-------|
| **Session ID** | \`${session.id}\` |
| **Started** | ${session.startTime.toISOString()} |
| **Completed** | ${session.endTime.toISOString()} |
| **Duration** | ${durationMin}m ${durationSec}s |
| **Cost** | $${session.cost.toFixed(4)} |

### Summary
${session.summary}
${session.details ? `\n### Details\n${session.details}` : ''}

---
<sub>🤖 Automated by auto-dev</sub>`;

    await this.octokit.issues.createComment({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
      body,
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // Implementation Plan (Comments with Markers)
  // ─────────────────────────────────────────────────────────────────

  /**
   * Check if an implementation plan exists for an issue.
   */
  async hasImplementationPlan(issueNumber: number): Promise<boolean> {
    const plan = await this.getImplementationPlan(issueNumber);
    return plan !== null;
  }

  /**
   * Get the implementation plan from issue comments.
   * Uses markers for reliable extraction.
   */
  async getImplementationPlan(issueNumber: number): Promise<string | null> {
    const { data: comments } = await this.octokit.issues.listComments({
      owner: this.owner,
      repo: this.repo,
      issue_number: issueNumber,
    });

    for (const comment of comments) {
      if (comment.body?.includes(PLAN_START_MARKER)) {
        const startIdx = comment.body.indexOf(PLAN_START_MARKER);
        const endIdx = comment.body.indexOf(PLAN_END_MARKER);
        if (endIdx > startIdx) {
          return comment.body.slice(startIdx, endIdx + PLAN_END_MARKER.length);
        }
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────
  // Issue Discovery
  // ─────────────────────────────────────────────────────────────────

  /**
   * Find all in-progress issues (have auto-dev phase labels).
   */
  async findInProgressIssues(): Promise<
    Array<{ number: number; phase: Phase; title: string }>
  > {
    const phases: Phase[] = [
      'selecting',
      'planning',
      'implementing',
      'pr-waiting',
      'reviewing',
      'fixing',
      'merging',
      'verifying',
    ];

    const results: Array<{ number: number; phase: Phase; title: string }> = [];

    for (const phase of phases) {
      const { data: issues } = await this.octokit.issues.listForRepo({
        owner: this.owner,
        repo: this.repo,
        labels: `auto-dev:${phase}`,
        state: 'open',
      });

      for (const issue of issues) {
        results.push({
          number: issue.number,
          phase,
          title: issue.title,
        });
      }
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────

  private isPhaseLabel(label: string): boolean {
    const phases = [
      'selecting',
      'planning',
      'implementing',
      'pr-waiting',
      'reviewing',
      'fixing',
      'merging',
      'verifying',
      'complete',
      'blocked',
      'ci-failed',
    ];
    const phase = label.replace('auto-dev:', '');
    return phases.includes(phase);
  }

  private formatPhase(phase: Phase): string {
    const map: Record<Phase, string> = {
      selecting: 'Issue Selection',
      planning: 'Planning',
      implementing: 'Implementation',
      'pr-waiting': 'CI Wait',
      reviewing: 'Code Review',
      fixing: 'Fix Review Feedback',
      merging: 'Merge & Deploy',
      verifying: 'Verification',
      complete: 'Complete',
      blocked: 'Blocked',
      'ci-failed': 'CI Failed',
    };
    return map[phase] || phase;
  }
}
```

### Graceful Shutdown Handler

```typescript
// src/process/signals.ts

import { ChildProcess } from 'node:child_process';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import { logger } from '../logger';

const execAsync = promisify(exec);

// Track all spawned child processes
const activeProcesses = new Set<ChildProcess>();
let isShuttingDown = false;

/**
 * Register a child process for tracking.
 * Automatically removed when process exits.
 */
export function trackProcess(process: ChildProcess): void {
  activeProcesses.add(process);
  process.on('exit', () => activeProcesses.delete(process));
}

/**
 * Graceful shutdown handler.
 *
 * - Kills all tracked child processes
 * - Cleans up port 3000 (dev servers)
 * - Terminates node processes for this project
 */
export async function gracefulShutdown(): Promise<void> {
  if (isShuttingDown) return;
  isShuttingDown = true;

  logger.info({ activeProcesses: activeProcesses.size }, 'Initiating shutdown');

  // Kill all tracked child processes
  const killPromises = Array.from(activeProcesses).map(
    (proc) =>
      new Promise<void>((resolve) => {
        if (proc.killed) {
          resolve();
          return;
        }

        const timeout = setTimeout(() => {
          if (!proc.killed) {
            logger.warn({ pid: proc.pid }, 'Force killing process');
            proc.kill('SIGKILL');
          }
          resolve();
        }, 5000);

        proc.on('exit', () => {
          clearTimeout(timeout);
          resolve();
        });

        proc.kill('SIGTERM');
      })
  );

  await Promise.all(killPromises);

  // Kill processes on port 3000 (dev servers)
  await killPort(3000);

  // Kill node processes for this project directory
  await killNodeProcesses(process.cwd());

  logger.info('Shutdown complete');
}

/**
 * Kill all processes listening on a port.
 */
async function killPort(port: number): Promise<void> {
  try {
    const { stdout } = await execAsync(`lsof -ti:${port}`);
    const pids = stdout.trim().split('\n').filter(Boolean);

    for (const pid of pids) {
      logger.info({ pid, port }, 'Killing process on port');
      await execAsync(`kill ${pid}`).catch(() => {});
    }
  } catch {
    // No processes on port
  }
}

/**
 * Kill node processes running in a directory.
 */
async function killNodeProcesses(directory: string): Promise<void> {
  try {
    const { stdout } = await execAsync(`pgrep -f "node.*${directory}"`);
    const pids = stdout.trim().split('\n').filter(Boolean);

    for (const pid of pids) {
      logger.info({ pid, directory }, 'Killing node process');
      await execAsync(`kill ${pid}`).catch(() => {});
    }
  } catch {
    // No matching processes
  }
}

/**
 * Setup signal handlers for graceful shutdown.
 * Call this once at application startup.
 */
export function setupSignalHandlers(): void {
  process.on('SIGTERM', async () => {
    logger.info('Received SIGTERM');
    await gracefulShutdown();
    process.exit(0);
  });

  process.on('SIGINT', async () => {
    logger.info('Received SIGINT');
    await gracefulShutdown();
    process.exit(0);
  });
}
```

---

## Build & Distribution

### Package.json

```json
{
  "name": "auto-dev",
  "version": "1.0.0",
  "description": "Automated development loop with Claude Code",
  "type": "module",
  "bin": {
    "auto-dev": "./dist/index.js"
  },
  "scripts": {
    "build": "tsup src/index.ts --format esm --dts --clean",
    "build:binary": "bun build src/index.ts --compile --outfile auto-dev",
    "build:binary:linux": "bun build src/index.ts --compile --target=bun-linux-x64 --outfile auto-dev-linux",
    "build:binary:windows": "bun build src/index.ts --compile --target=bun-windows-x64 --outfile auto-dev.exe",
    "dev": "tsx src/index.ts",
    "dev:watch": "tsx watch src/index.ts",
    "test": "vitest",
    "test:coverage": "vitest --coverage",
    "lint": "eslint src --ext .ts",
    "lint:fix": "eslint src --ext .ts --fix",
    "typecheck": "tsc --noEmit",
    "format": "prettier --write src",
    "prepare": "npm run build"
  },
  "dependencies": {
    "@octokit/rest": "^20.0.0",
    "clipanion": "^4.0.0",
    "cosmiconfig": "^9.0.0",
    "dotenv": "^16.0.0",
    "pino": "^8.0.0",
    "xstate": "^5.0.0",
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "@types/node": "^20.0.0",
    "eslint": "^8.0.0",
    "pino-pretty": "^10.0.0",
    "prettier": "^3.0.0",
    "tsup": "^8.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.3.0",
    "vitest": "^1.0.0"
  },
  "engines": {
    "node": ">=20.0.0"
  }
}
```

### Bun Compile Details

**What Bun `--compile` produces:**

Bun's compile feature creates a **self-contained executable** that bundles:
1. Your bundled JavaScript/TypeScript code
2. A copy of the Bun runtime (~50MB)

**Important:** This is **NOT** native machine code like Rust/Go. It's your JS code embedded in a native binary containing the Bun runtime.

| Aspect | Value |
|--------|-------|
| Output | Single executable binary |
| Size (macOS) | ~50MB |
| Size (Windows) | ~100MB |
| Startup | Fast (runtime init overhead) |
| Dependencies | None required on target machine |
| Cross-compile | Yes (--target flag) |

**Cross-compilation targets:**

```bash
# macOS ARM64 (M1/M2)
bun build src/index.ts --compile --target=bun-darwin-arm64 --outfile auto-dev-macos-arm64

# macOS x64 (Intel)
bun build src/index.ts --compile --target=bun-darwin-x64 --outfile auto-dev-macos-x64

# Linux x64
bun build src/index.ts --compile --target=bun-linux-x64 --outfile auto-dev-linux

# Windows x64
bun build src/index.ts --compile --target=bun-windows-x64 --outfile auto-dev.exe
```

**Optional bytecode compilation:**

```bash
bun build src/index.ts --compile --bytecode --outfile auto-dev
```

- Moves parsing from runtime to build time
- Faster startup for large codebases
- Does NOT obscure source code (not obfuscation)
- Only supports CommonJS format currently (experimental)

### Alternative: Node.js Distribution

If you prefer Node.js over Bun:

1. **npm/npx distribution:**
   ```bash
   # Users install globally
   npm install -g auto-dev

   # Or run via npx
   npx auto-dev --once
   ```

2. **pkg (standalone binary):**
   ```bash
   npx pkg . --targets node20-macos-arm64,node20-linux-x64,node20-win-x64
   ```

---

## Migration Strategy

### Phase 1: Foundation (Week 1)

**Goal:** Port the GitHub memory layer and configuration.

1. Set up TypeScript project structure
2. Implement `GitHubMemory` class
3. Implement `ConfigSchema` with Zod
4. Write unit tests for memory operations
5. Verify label management works correctly

**Deliverable:** Can read/write GitHub labels and comments.

### Phase 2: Claude Integration (Week 2)

**Goal:** Port the Claude session runner and stream parser.

1. Implement `ClaudeSession` class
2. Implement `StreamParser` for JSON output
3. Add event emission for progress display
4. Write tests with captured stream fixtures
5. Verify streaming output displays correctly

**Deliverable:** Can run Claude sessions and parse output.

### Phase 3: Individual Phases (Week 3-4)

**Goal:** Port each workflow phase function.

1. Port `selectIssue` (Session 1)
2. Port `planImplementation` (Session 2)
3. Port `implementAndTest` (Session 3)
4. Port `waitForCI` (CI polling)
5. Port `reviewCode` (Session 4)
6. Port `fixReviewFeedback` (Session 5)
7. Port `mergeAndVerify` (Session 6)
8. Port `updateDocumentation` (Session 7)

**Deliverable:** Each phase can run independently.

### Phase 4: State Machine (Week 5)

**Goal:** Wire up XState machine and orchestrator.

1. Define XState machine with all states
2. Implement phase service invocations
3. Add resume logic for crash recovery
4. Implement guard conditions (max review rounds)
5. Write state transition tests

**Deliverable:** Full workflow runs via state machine.

### Phase 5: CLI & Polish (Week 6)

**Goal:** Complete CLI and add production features.

1. Implement Clipanion commands
2. Add graceful shutdown handlers
3. Implement logging with Pino
4. Add `--status` output formatting
5. Write integration tests

**Deliverable:** Feature-complete CLI.

### Phase 6: Validation (Week 7)

**Goal:** Parallel testing and bug fixes.

1. Run both bash and TypeScript versions in parallel
2. Compare outputs and behavior
3. Fix any discrepancies
4. Performance testing
5. Documentation updates

**Deliverable:** TypeScript version passes all tests.

### Phase 7: Cutover (Week 8)

**Goal:** Replace bash script with TypeScript.

1. Final testing on real issues
2. Update README with new installation instructions
3. Deprecate bash script
4. Create release with binaries

**Deliverable:** Production-ready TypeScript auto-dev.

---

## References

### Official Documentation

- [Clipanion CLI Framework](https://github.com/arcanis/clipanion)
- [XState Documentation](https://stately.ai/docs/xstate)
- [XState Visualizer](https://stately.ai/viz)
- [Octokit REST API](https://octokit.github.io/rest.js)
- [Pino Logger](https://getpino.io/)
- [Zod Schema Validation](https://zod.dev/)
- [Bun Single-file Executables](https://bun.sh/docs/bundler/executables)

### Comparison Articles

- [Bun vs Node.js TypeScript](https://betterstack.com/community/guides/scaling-nodejs/bun-vs-nodejs-typescript/)
- [Pino vs Winston Performance](https://betterstack.com/community/comparisons/pino-vs-winston/)
- [Commander vs Yargs](https://npm-compare.com/commander,yargs)

### Design Patterns

- [Node.js Child Process Streams](https://2ality.com/2018/05/child-process-streams.html)
- [Graceful Shutdown in Node.js](https://dev.to/superiqbal7/graceful-shutdown-in-nodejs-handling-stranger-danger-29jo)
- [TypeScript Configuration with Zod](https://dev.to/schead/ensuring-environment-variable-integrity-with-zod-in-typescript-3di5)

### Related Projects

- [Claude Code (Anthropic CLI)](https://github.com/anthropics/claude-code)
- [Anthropic TypeScript SDK](https://github.com/anthropics/anthropic-sdk-typescript)
- [Anthropic Agent SDK (Python)](https://github.com/anthropics/anthropic-cookbook)

---

## Appendix: Bash to TypeScript Mapping

| Bash Pattern | TypeScript Equivalent |
|--------------|----------------------|
| `set -euo pipefail` | Try/catch, TypeScript strict mode |
| `trap cleanup EXIT` | `process.on('SIGTERM', ...)` |
| `$(command)` | `await execAsync('command')` |
| `jq '.field'` | `data.field` (typed) |
| `grep -q pattern` | `string.includes()` or regex |
| `echo "$var"` | `logger.info({ var })` |
| `[ -z "$var" ]` | `if (!var)` |
| `while read line` | `for await (const line of ...)` |
| `ARRAY+=("item")` | `array.push('item')` |
| `${var:-default}` | `var ?? 'default'` |
| `local var` | `const var` (block scoped) |
| `function name()` | `function name(): ReturnType` |
| `source file.sh` | `import { ... } from './file'` |
| `"$@"` | `...args: string[]` |
| Colors (`\033[0;32m`) | `chalk.green()` or Pino formatters |
