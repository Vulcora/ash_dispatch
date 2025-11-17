# AshDispatch Extraction Guide

Step-by-step guide to extract AshDispatch from Magasin into a standalone library.

---

## Prerequisites

- [x] AshDispatch code ready in `lib/ash_dispatch/`
- [x] All tests passing
- [x] Config references use `:ash_dispatch` namespace
- [x] Standalone `mix.exs` created
- [x] Documentation files ready
- [ ] GitHub access to Vulcora org
- [ ] Git configured locally

---

## Step 1: Create GitHub Repository

### 1.1 Create Private Repo

1. Go to https://github.com/organizations/Vulcora/repositories/new
2. Repository name: `ash_dispatch`
3. Description: `Event-driven notification system for Ash Framework`
4. Visibility: **Private**
5. Initialize: **Do NOT add README, .gitignore, or license** (we have these)
6. Click "Create repository"

### 1.2 Note Repository URL

```
git@github.com:Vulcora/ash_dispatch.git
```

---

## Step 2: Prepare Extraction Directory

### 2.1 Create New Directory

```bash
cd ~/Projects
mkdir ash_dispatch
cd ash_dispatch
git init
```

### 2.2 Copy Files from Magasin

```bash
# Copy main lib directory
cp -r ~/Projects/magasin/lib/ash_dispatch/* .

# Move mix.exs to root (it's currently in lib/ash_dispatch/)
mv mix.exs mix.exs.tmp
cd ..
mv lib/ash_dispatch/mix.exs .
rm -rf lib/ash_dispatch
mkdir -p lib/ash_dispatch
mv mix.exs.tmp/* lib/ash_dispatch/

# Copy test directory
cp -r ~/Projects/magasin/test/ash_dispatch test/
cp -r ~/Projects/magasin/test/support/ash_dispatch test/support/

# Copy documentation
# (already in lib/ash_dispatch/documentation/)

# Copy README, LICENSE, CHANGELOG
# (already in lib/ash_dispatch/)
```

**Simplified approach - copy everything except mix.exs to lib/:**

```bash
cd ~/Projects/ash_dispatch

# Copy entire ash_dispatch directory
cp -r ~/Projects/magasin/lib/ash_dispatch/* lib/

# Move files that should be in root
mv lib/mix.exs .
mv lib/README.md .
mv lib/LICENSE .
mv lib/CHANGELOG.md .

# Copy tests
mkdir -p test
cp -r ~/Projects/magasin/test/ash_dispatch/* test/
```

### 2.3 Create .gitignore

```bash
cat > .gitignore << 'EOF'
# Elixir
/_build
/cover
/deps
/doc
/.fetch
erl_crash.dump
*.ez
*.beam
/config/*.secret.exs
.elixir_ls/

# IDEs
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Temporary files
*.tmp
*.log
EOF
```

### 2.4 Create .formatter.exs

```bash
cat > .formatter.exs << 'EOF'
[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
EOF
```

---

## Step 3: Initialize Git Repository

### 3.1 Initial Commit

```bash
cd ~/Projects/ash_dispatch

git add .
git commit -m "Initial commit: Extract AshDispatch from Magasin

AshDispatch is an event-driven notification system for Ash Framework.

Features:
- Resource-level dispatch DSL
- Multiple transport types (email, in-app, webhooks)
- Delivery tracking with state machine
- Automatic retry system
- User preference checking
- Swoosh email backend integration
- Discord and Slack webhook support

This is v0.1.0 - initial alpha release."
```

### 3.2 Add Remote and Push

```bash
git remote add origin git@github.com:Vulcora/ash_dispatch.git
git branch -M main
git push -u origin main
```

### 3.3 Tag Initial Release

```bash
git tag -a v0.1.0 -m "Initial alpha release

First extraction of AshDispatch from Magasin project.

Core features:
- Event dispatcher with multiple transports
- Email (Swoosh), In-App, Discord, Slack, generic Webhook
- Delivery receipt tracking
- Automatic retry system
- Comprehensive documentation"

git push origin v0.1.0
```

---

## Step 4: Verify Standalone Build

### 4.1 Install Dependencies

```bash
cd ~/Projects/ash_dispatch
mix deps.get
```

### 4.2 Compile

```bash
mix compile
```

**Expected:** Should compile without errors (may have warnings about missing config - that's OK for library)

### 4.3 Run Tests

**Note:** Tests require database and config setup from host application. Standalone tests will fail initially - this is expected.

For now, skip standalone test verification. Tests will be verified in Magasin integration (Step 6).

---

## Step 5: Generate Documentation

### 5.1 Generate HTML Docs

```bash
cd ~/Projects/ash_dispatch
mix docs
```

### 5.2 Verify Docs Generated

```bash
ls doc/
# Should show: index.html, assets/, fonts/, dist/, etc.
```

### 5.3 Open Docs Locally

```bash
open doc/index.html
# Or: python3 -m http.server 8080 (inside doc/)
```

### 5.4 Commit Documentation

```bash
git add doc/
git commit -m "Add generated documentation (ex_doc)"
git push
```

---

## Step 6: Update Magasin to Use Path Dependency

### 6.1 Update mix.exs

Edit `~/Projects/magasin/mix.exs`:

```elixir
defp deps do
  [
    # AshDispatch - use path dependency during development
    {:ash_dispatch, path: "../ash_dispatch"},

    # When ready for production:
    # {:ash_dispatch, github: "Vulcora/ash_dispatch", branch: "main"},
    # or:
    # {:ash_dispatch, github: "Vulcora/ash_dispatch", tag: "v0.1.0"},

    # ... other deps
  ]
end
```

### 6.2 Update Dependencies

```bash
cd ~/Projects/magasin
mix deps.get
```

**Expected output:**
```
* Getting ash_dispatch (../ash_dispatch)
```

### 6.3 Compile

```bash
mix compile
```

**Expected:** Clean compilation (or same warnings as before)

---

## Step 7: Verify Integration

### 7.1 Run AshDispatch Tests from Magasin

```bash
cd ~/Projects/magasin
mix test test/ash_dispatch/
```

**Expected:** All tests pass (same as before extraction)

### 7.2 Run Specific Test Suite

```bash
# Dispatcher tests
mix test test/ash_dispatch/dispatcher_test.exs

# Transport tests
mix test test/ash_dispatch/transports/

# Worker tests
mix test test/ash_dispatch/workers/

# Email backend tests
mix test test/ash_dispatch/email_backend/
```

### 7.3 Verify Config Still Works

```bash
cd ~/Projects/magasin
iex -S mix

# In IEx:
iex> Application.get_env(:ash_dispatch, :email_backend)
AshDispatch.EmailBackend.Swoosh  # (or Mock in test env)

iex> Application.get_env(:ash_dispatch, :default_from_email)
"noreply@fyndgrossisten.se"  # (or example.com in test)
```

---

## Step 8: Test Simultaneous Development

### 8.1 Make Test Change in AshDispatch

```bash
cd ~/Projects/ash_dispatch
echo "# Test comment" >> lib/ash_dispatch/dispatcher.ex
```

### 8.2 Verify Instant Availability in Magasin

```bash
cd ~/Projects/magasin
mix compile
# Should recompile ash_dispatch immediately

grep "# Test comment" deps/ash_dispatch/lib/ash_dispatch/dispatcher.ex
# Should find the comment
```

### 8.3 Revert Test Change

```bash
cd ~/Projects/ash_dispatch
git checkout lib/ash_dispatch/dispatcher.ex
```

---

## Step 9: Commit Magasin Changes

### 9.1 Update Magasin

```bash
cd ~/Projects/magasin

git add mix.exs mix.lock
git commit -m "Use AshDispatch via path dependency

Switch to extracted AshDispatch library during development.

Changes:
- Updated mix.exs to use path dependency: ../ash_dispatch
- Removed lib/ash_dispatch/ (now in separate repo)
- Kept test/ash_dispatch/ for integration tests
- Config remains in Magasin (host application responsibility)

The path dependency allows simultaneous development of both repos
without lag from git commits. Will switch to github dependency when
stabilized for production."

git push
```

---

## Step 10: Optional - GitHub Pages Setup

If you want online documentation (private to team):

### 10.1 Rename doc/ to docs/

```bash
cd ~/Projects/ash_dispatch
mv doc docs
```

### 10.2 Update mix.exs

```elixir
# In docs() function:
output: "docs"  # instead of default "doc"
```

### 10.3 Commit and Push

```bash
git add .
git commit -m "Setup GitHub Pages documentation"
git push
```

### 10.4 Enable GitHub Pages

1. Go to repo Settings → Pages
2. Source: Deploy from a branch
3. Branch: `main` / `docs`
4. Click Save

Docs will be at: `https://vulcora.github.io/ash_dispatch/`

---

## Step 11: Cleanup Magasin (Optional)

### 11.1 Remove Extracted Code

```bash
cd ~/Projects/magasin

# Remove lib/ash_dispatch/ since it's now external
rm -rf lib/ash_dispatch/

# Keep test/ash_dispatch/ for integration tests

git add .
git commit -m "Remove extracted AshDispatch code

AshDispatch code moved to separate repository.
Keeping integration tests in test/ash_dispatch/.
Using path dependency during development."
git push
```

---

## Verification Checklist

After extraction, verify:

- [ ] AshDispatch repo exists at github.com/Vulcora/ash_dispatch
- [ ] Repository is private
- [ ] v0.1.0 tag exists
- [ ] Documentation committed to repo (doc/ or docs/)
- [ ] Magasin uses path dependency: `{:ash_dispatch, path: "../ash_dispatch"}`
- [ ] All tests pass: `cd ~/Projects/magasin && mix test test/ash_dispatch/`
- [ ] Compilation clean: `mix compile`
- [ ] Config still works (check in IEx)
- [ ] Changes in ash_dispatch/ immediately available in Magasin
- [ ] Both repos can be developed simultaneously without lag

---

## Switching to Git Dependency (Later)

When ready to stabilize and use git dependency:

### Using Branch (Development/Staging)

```elixir
# mix.exs
{:ash_dispatch, github: "Vulcora/ash_dispatch", branch: "main"}
```

### Using Tag (Production)

```elixir
# mix.exs
{:ash_dispatch, github: "Vulcora/ash_dispatch", tag: "v0.1.0"}
```

### Update and Test

```bash
mix deps.update ash_dispatch
mix compile
mix test test/ash_dispatch/
```

---

## Troubleshooting

### "dependency ash_dispatch did not compile"

```bash
# Clean and retry
cd ~/Projects/magasin
mix deps.clean ash_dispatch
mix deps.get
mix compile
```

### "cannot find path ../ash_dispatch"

Check both repos are side-by-side:
```bash
ls ~/Projects/
# Should show both: magasin/ and ash_dispatch/
```

### Tests failing after extraction

1. Check config still set: `Application.get_env(:ash_dispatch, :email_backend)`
2. Verify test support files copied: `ls test/ash_dispatch/support/`
3. Run specific failing test with verbose: `mix test test/ash_dispatch/failing_test.exs --trace`

### Documentation not generating

```bash
cd ~/Projects/ash_dispatch
mix deps.get  # Ensure ex_doc installed
mix docs --verbose  # See detailed output
```

---

## Next Steps

After successful extraction:

1. **Develop Features:** Make changes in `~/Projects/ash_dispatch`, test in Magasin immediately
2. **Commit Often:** Commit to both repos as you develop
3. **Tag Releases:** Create semantic version tags in ash_dispatch repo
4. **Update Docs:** Regenerate and commit docs after major changes
5. **Team Access:** Add team members to private Vulcora/ash_dispatch repo

---

## Support

Questions or issues during extraction?
- Check DISPATCH_WORKFLOW.md for detailed development workflow
- Review test output for specific errors
- Verify both repos are at same directory level
- Ensure git credentials configured for Vulcora org
