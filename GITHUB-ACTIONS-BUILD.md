# ContextWard Build via GitHub Actions

**No Xcode installation needed. No macOS upgrade needed.**

GitHub Actions will build the app on a remote macOS runner. You download the built app and test it locally.

---

## Setup (One-Time)

### 1. Push Code to GitHub
```bash
cd /Users/pharos_ai/agent-work/contextward

# If not a git repo yet:
git init
git add .
git commit -m "ContextWard remediation: code changes and acceptance test plan"
git remote add origin https://github.com/YOUR_USERNAME/contextward.git
git branch -M main
git push -u origin main
```

### 2. Enable GitHub Actions
- Go to your repo on github.com
- Click "Actions" tab
- Click "I understand my workflows, go ahead and enable them"

---

## Build (On Every Push)

The workflow automatically triggers when you push to GitHub.

### To build now:
```bash
cd /Users/pharos_ai/agent-work/contextward
git add -A
git commit -m "Trigger build"
git push
```

### To monitor the build:
1. Go to github.com/YOUR_USERNAME/contextward
2. Click "Actions" tab
3. Click the latest workflow run
4. Wait for "Build ContextWard macOS App" to complete (5–10 min)
5. Once green ✓, click "Summary"
6. Scroll to "Artifacts" section
7. Download "FollowUpOSNative-app" (the .app bundle)

---

## Test the Downloaded App

Once downloaded:

```bash
# Extract the app (if in zip)
unzip FollowUpOSNative-app.zip

# Launch it
open FollowUpOSNative.app
```

Then execute ACCEPTANCE-TEST-PLAN-20261014.md (27 steps).

---

## What Happens in GitHub Actions

The workflow:
1. Checks out your code on a macOS runner
2. Verifies Xcode is installed (it is on GitHub runners)
3. Runs: `xcodebuild -scheme FollowUpOSNative -workspace FollowUpOSNative.xcworkspace -configuration Release`
4. Finds the built app
5. Creates a DMG (disk image) for distribution
6. Uploads both as artifacts you can download

**You don't need Xcode on your Mac.** The remote runner builds it.

---

## After Testing

Once you've run the 27-step acceptance test:
1. Report results (which steps passed/failed)
2. I complete the final verification record
3. Deliverable is done

---

## Troubleshooting

**"Workflow not triggering"**: 
- Make sure GitHub Actions is enabled in repo settings
- Try manually triggering: "Actions" → "Build ContextWard macOS App" → "Run workflow"

**"Build failed"**:
- Click the failed run in Actions
- Scroll down to see error message
- Report error to me; likely a code issue or missing dependency

**"Can't download artifacts"**:
- Artifacts expire after 30 days
- If needed, re-run the workflow to rebuild

---

## This Unblocks the Deliverable

With GitHub Actions:
- ✓ No need to upgrade your Mac
- ✓ No need to install Xcode locally
- ✓ No need to access another Mac
- ✓ Built app downloads to your Mac
- ✓ You run the 27-step acceptance test
- ✓ Deliverable completes

**Time commitment**: ~10 min setup + 5 min per push + 45 min to run test = ~1 hour total.
