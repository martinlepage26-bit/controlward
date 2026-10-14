# ContextWard Deliverable — Completion Checklist

**Status**: Awaiting your action to complete  
**Effort Remaining**: 2–3 hours  
**Blocker**: Xcode installation on your Mac

---

## Phase 1: Install Xcode (1–2 hours)

Choose ONE of these methods:

### Option A: App Store (Easiest)
- [ ] Open App Store app
- [ ] Search for "Xcode"
- [ ] Click "Install"
- [ ] Wait for download (~12 GB)
- [ ] Verify: `xcode-select -p` should return `/Applications/Xcode.app/Contents/Developer`

### Option B: Via `mas` CLI
- [ ] `brew install mas` (if you have Homebrew)
- [ ] `mas install 497799835`
- [ ] Wait for installation
- [ ] Verify: `xcode-select -p`

### Option C: Manual Download
- [ ] Visit https://developer.apple.com/download
- [ ] Search for "Xcode"
- [ ] Download `.xip` file (~12 GB)
- [ ] Double-click to extract and install
- [ ] Verify: `xcode-select -p`

**Verification**:
```bash
xcode-select -p
# Should output: /Applications/Xcode.app/Contents/Developer

xcodebuild -version
# Should output Xcode version info
```

---

## Phase 2: Build the App (5–10 minutes)

- [ ] Run the build script: `bash /Users/pharos_ai/agent-work/contextward/BUILD-AND-TEST.sh`
- [ ] Script will check Xcode, build the app, and launch it
- [ ] Wait for "✓ App launched" message
- [ ] App should open in a new window

**Manual build (if script fails)**:
```bash
cd /Users/pharos_ai/agent-work/contextward/native-crm
xcodebuild -scheme FollowUpOSNative -workspace FollowUpOSNative.xcworkspace -configuration Release build
```

---

## Phase 3: Run Acceptance Test (30–45 minutes)

Open: `/Users/pharos_ai/agent-work/contextward/ACCEPTANCE-TEST-PLAN-20261014.md`

Follow all 27 steps in order:
- [ ] Phase 1: Setup (steps 1–3)
- [ ] Phase 2: Company and Contact (steps 4–8)
- [ ] Phase 3: Lead and Notes (steps 9–13)
- [ ] Phase 4: Opportunity and Task (steps 14–19)
- [ ] Phase 5: Persistence Verification (steps 20–23) — **CRITICAL**
- [ ] Phase 6: Error State Verification (steps 24–27)

**Critical step**: Step 21–23 test persistence after quit/reopen.
- After step 19, quit the app (Cmd+Q)
- Reopen the app
- Verify every link created in steps 4–19 still exists

---

## Phase 4: Report Results (5 minutes)

Once all 27 steps are complete, report:

**Send this to Claude**:

```
Acceptance test results:

Phase 1 (Setup): [PASS/FAIL]
- Auto-Pilot shows OFF: [YES/NO]

Phase 2 (Company & Contact): [PASS/FAIL]
- Company created: [YES/NO]
- Contact created with company link: [YES/NO]
- Company shown in contact subtitle: [YES/NO]

Phase 3 (Lead & Notes): [PASS/FAIL]
- Lead created with company link: [YES/NO]
- Note created with contact and company links: [YES/NO]

Phase 4 (Opportunity & Task): [PASS/FAIL]
- Opportunity created with contact/company: [YES/NO]
- Task created with all relationships: [YES/NO]

Phase 5 (Persistence - CRITICAL): [PASS/FAIL]
- After quit/reopen, lead shows company: [YES/NO]
- After quit/reopen, contact shows company: [YES/NO]
- After quit/reopen, note shows contact and company: [YES/NO]
- After quit/reopen, opportunity shows contact/company: [YES/NO]
- After quit/reopen, task shows contact/company/opportunity: [YES/NO]

Phase 6 (Error State): [PASS/FAIL]
- Invalid PHAROS endpoint shows friendly error: [YES/NO]
- No raw API error text visible: [YES/NO]

Overall: [ALL PASS / PARTIAL PASS / FAILED]
Any issues encountered: [DESCRIBE]
```

---

## What Happens After You Report

Once results are reported, I will:

1. Update FINAL-REPORT-20261014.md with running-app verification evidence
2. Mark promises #1, #3, #7, #9 as "running-app-verified" (moving from inspection-only)
3. Create final ACCEPTANCE-TEST-RESULTS-20261014.md with full details
4. Confirm deliverable is complete

**Expected outcome**: All 4 promises move to "verified" status, and the deliverable is signed off.

---

## Timeline

| Phase | Task | Time | Status |
|-------|------|------|--------|
| 1 | Install Xcode | 1–2 hrs | ⏳ Awaiting your action |
| 2 | Build app | 5–10 min | ⏳ Awaiting Xcode |
| 3 | Run 27-step test | 30–45 min | ⏳ Awaiting build |
| 4 | Report results | 5 min | ⏳ Awaiting test |
| 5 | Final verification | 15 min | ⏳ Awaiting report |
| **Total** | | **2–3 hours** | |

---

## Questions?

- **Build fails**: Check that Xcode is fully installed (`xcode-select -p` should show `/Applications/Xcode.app/...`)
- **App won't launch**: Try manual build command above
- **Test step unclear**: Re-read that step in ACCEPTANCE-TEST-PLAN-20261014.md
- **Relationship not visible**: Check that the picker was used (not just typed into a text field)

---

**Next action**: Install Xcode, then run `bash BUILD-AND-TEST.sh`
