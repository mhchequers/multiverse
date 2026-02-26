# Multiverse

Multiverse is a macOS app for managing my work, whether it be related to experiments and R&D work, or data analytics work. The app has integrated terminals and Claude Code sessions, and was built for my work on the Convictional Research and Data Analytics teams. 

Multiverse allows for multiple isolated git worktrees per piece of work, allowing multiple pieces of work to run concurrently and separate from each other.

Named for the multiverse theory in theoretical physics, it suggests productivity isn't limited to a single linear path, and allows multiple (infinite!) realities to exist at the same time. 

## Prerequisites

- macOS 15+ (Sequoia)
- Xcode 16+ - required for Swift 6.0 toolchain (or just the Swift 6.0 command-line tools)
- Git - the app shells out to /usr/bin/git for all git operations (status, diff, worktrees,     
  commit detection, etc.) 
- Claude CLI - `claude` must be in your `PATH`

## Getting started

```
git clone <repo-url> multiverse
cd multiverse
```

### Build and run

```
make build      # compile only
make run        # compile + launch
```

### Clean

```
make clean
```

## How it works

Multiverse is effectively a Claude code wrapper with VSCode features, and enables multiple instances of Claude code in different repos to run concurrently.

Loom demoing the app is [here](https://www.loom.com/share/73cc9c150c6641be8f16a41b1eabbaa9).

- **Create a project**
    - Enter a title and description. Markdown is supported in the description.
    - Select the git repository to base off of.
    - Select the git branch to base off of and enter a branch name for the project.
    - A git worktree is automatically created for the repo and branch.
- **Select a project**
    - Pick up where you left off and select a project in the left pane.
- **Edit description**
    - You can edit the description as you need. Markdown is supported.
- **Add notes**
    - Add notes about the project as you need. Markdown is supported.
- **Create and execute a code plan**
    - Edit the base template for the code plan
    - Execute the plan. Claude code is spawned in a new terminal with the plan injected, and in plan mode, to execute on the work you described.
    - You can reset the plan and run a new one at any time.
- **Explore via terminal**
    - A terminal is spawned when clicking on or creating a new project.
    - you can create multiple terminals.
- **Track git changes**
    - Git changes are tracked and displayed similar to VSCode.
    - A single click on a file shows a single view diff of the changes.
    - A double click on a file shows a side-by-side view of the changes.
    - Line alterations are shown very similarly to VSCode.
- **File explorer**
    - Explore the repo files.
    - Make edits to the repo files.
    - Language-specific syntax highlighting is included.
- **Look at the timeline of activity**
    - See the activity history for the project.
- **Delete a project**
    - Click Delete to permanently delete the project.
    - The git worktree is automaticaly cleaned up.
- **Archive a project**
    - After a project is complete, you can archive it.
    - After the project is archived, you can manually clean up the git worktree associated with it.
    - You can also move the project back to in progress, and a git worktree will automatically be created (if one doesn't exist).
