# ControlWard design system

## Overview

A native macOS operations workspace used for sustained reading and review. The
existing light shell stays light; Project Control retains its own dark dashboard.
Both share one navigation home. The contrast between the two surfaces identifies
their different records and authority rather than implying shared storage.

## Colors

| Role | Value | Use |
| --- | --- | --- |
| Ink | #1B2430 | Primary text and structure |
| Paper | #F7F5F0 | Existing application background |
| Amber | #E8A33D | Existing logo / dark-surface accent |
| Action amber | #875712 | Buttons, links and the Ward wordmark on light surfaces |
| Slate | #5B6472 | Secondary labels |
| Steel | #3E6C8E | Neutral workflow icons |
| Moss | #4C7A5E | Confirmed positive state |
| Rust | #B5482F | Overdue or attention state |
| Border | #E4E0D6 | Subtle separators |

The source of truth is `native-crm/Sources/FollowUpOSNative/Theme.swift`.
Brand colors predate this pass; they are preserved rather than replaced with
an unrelated palette. Action amber is darker for readable text on light surfaces.

## Typography

SF system text throughout. Primary page titles use title2/bold; section titles use
headline; ordinary labels use body/callout and supporting text uses caption.
Counts and dates use monospaced digits where comparison matters. Avoid repeated
uppercase section labels. Reserve the rounded wordmark for the app identity.

## Layout and components

- One wordmark in the sidebar; a compact local-storage footer.
- 28-point page padding; 12–24-point rhythm for related content and sections.
- Overview: tasks carry the main weight, review queue beside them, compact
  workspace evidence below. Use ViewThatFits when the panes cannot fit.
- Native buttons, segmented controls, lists and file panels; one primary action
  per local decision group. Project capture shows its destination and provenance.
- Cards only group real tasks/forms; border without a decorative shadow.
- Opportunity stages scroll inside their own horizontal board.
- 180 ms notice transition; disabled when Reduce Motion is enabled.

## Validation boundary

Visual checks use the isolated synthetic preview. Its in-memory secret store and
nonpersistent WebKit stores are compiled only with DEBUG + CONTEXTWARD_ACCEPTANCE.
The release keeps the original bundle identifier and data path. Preview screenshots
are not evidence of a production register, mailbox or GAP connection.
