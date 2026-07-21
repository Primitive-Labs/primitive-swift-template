---
name: ios-design
description: >
  Idiomatic iOS / SwiftUI UI conventions for Primitive Swift apps. Triggers
  whenever a SwiftUI file (`.swift` containing `View`, `@StateObject`,
  `@EnvironmentObject`, `NavigationStack`, `List`, etc.) is being edited
  inside a `swift-primitive-app`-based project (detected by the presence of
  `PrimitiveAppTemplate`, `PrimitiveApp`, or `JsBaoClient` imports). Catches
  the multi-platform-gating, long-press-menu, foregroundStyle, permission-
  gating and other common Swift-side UI mistakes that the `primitive-platform`
  data-side skill doesn't cover. Use proactively after any SwiftUI edit; do
  not wait for the user to ask.
allowed-tools: Read, Edit, Grep, Glob, Bash
---

# iOS / SwiftUI design rules for Primitive apps

The `primitive-platform` skill enforces the **data** layer (TypedModel,
BaoDataLoader, getOrCreateWithAlias, etc.). This skill enforces the **UI**
layer — the conventions iOS users expect and the cross-platform gates the
template defaults to (iOS + macOS) require.

Use this skill any time you edit a `.swift` file containing SwiftUI types
in a project that imports `PrimitiveApp` / `JsBaoClient`. Run the
verification checklist at the end of every UI-editing session.

## When to trigger

- Edits to `Sources/**/Views/**.swift`.
- Files that contain `: View`, `@StateObject`, `@EnvironmentObject`,
  `NavigationStack`, `NavigationLink`, `List`, `Form`, `.task`,
  `.toolbar`, `.sheet`, `.alert`.
- After scaffolding a new SwiftUI view from any source.

Skip when:
- Editing pure data/model files (`models.toml`, `*Record.swift`, app-state
  business logic) — the `primitive-platform` skill covers those.
- Editing tests.
- The project is not Primitive-based (no `PrimitiveApp` / `JsBaoClient`
  imports anywhere in `Sources/`).

## Rules

### 1. Long-press / context menus on list rows

Any `NavigationLink` row inside a `List` that exposes mutations (rename,
delete, share, move) **must** attach a `.contextMenu { … }`. iOS users
expect long-press to surface row-level actions. Putting them only in a
detail-view toolbar buries them.

Pattern:

```swift
NavigationLink { Destination() } label: { Row() }
    .contextMenu {
        if ref.canEdit {
            Button { rename(ref) } label: { Label("Rename", systemImage: "pencil") }
        }
        Button { share(ref) } label: { Label("Share", systemImage: "person.crop.circle.badge.plus") }
        if ref.canEdit {
            Menu { /* Move to ▸ submenu */ } label: { Label("Move to", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { delete(ref) } label: { Label("Delete", systemImage: "trash") }
        }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        // Swipe is complementary, not a replacement.
    }
```

Swipe actions are still appropriate for the primary destructive action
(quick delete), but they shouldn't be the *only* path — long-press is the
discoverable surface.

### 2. Multi-platform gates

The template's default `project.yml` targets both iOS and macOS. These
SwiftUI APIs are iOS-only and **must** be wrapped in `#if os(iOS)` blocks
or the macOS build fails:

| API | Wrap in |
|---|---|
| `.navigationBarTitleDisplayMode(.inline)` | `#if os(iOS)` |
| `.textInputAutocapitalization(_:)` | `#if os(iOS)` |
| `.submitLabel(_:)` | `#if os(iOS)` |
| `.keyboardType(_:)` | `#if os(iOS)` |
| `.listStyle(.insetGrouped)` | `#if os(iOS)` |
| `.statusBar(hidden:)` / status bar APIs | `#if os(iOS)` |

Check with:

```bash
grep -nE "navigationBarTitleDisplayMode|textInputAutocapitalization|submitLabel|keyboardType|insetGrouped" Sources/**/*.swift | \
  grep -v "#if os(iOS)"
```

Any unwrapped hit is a build break on the macOS target.

### 3. `foregroundStyle` with conditional shape styles

```swift
.foregroundStyle(condition ? .tint : .secondary)        // ❌ type-checker rejects
.foregroundStyle(condition ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))   // ✅
```

`.tint`, `.secondary`, `.primary`, `.tertiary` are different concrete
`ShapeStyle` types. Ternaries across them need `AnyShapeStyle(...)` on
both branches.

### 4. Empty-state flash

Never write `if data.isEmpty { EmptyState() }` over `data = loader.data ?? []`.
The `?? []` collapses "not yet loaded" with "loaded, no items" and flashes
the placeholder. Use `BaoDataLoader.phase`:

```swift
switch loader.phase {
case .loading:        ProgressView()
case .empty:          EmptyState()
case .loaded(let d):  List(d) { … }
}
```

If for some reason `phase` isn't available (older PrimitiveApp version),
gate manually on `loader.initialDataLoaded`:

```swift
if !loader.initialDataLoaded { ProgressView() }
else if data.isEmpty { EmptyState() }
else { List(data) { … } }
```

### 5. Gate edit on `canEdit`, but DELETE on ownership

Rows representing shared data must gate row actions on permission — and
**delete is stricter than edit**. Only the document/collection *owner* can
delete it server-side; an editor (`read-write`) who taps Delete has the
call silently fail, and the row **reappears on the next reconcile** — a
confusing "it came back" bug. So split the gates:

- **Rename / move / edit content** → gate on `canEdit` (owner *or* read-write).
- **Delete the whole doc/collection** → gate on `isOwner` (owner only).
- **Share** → available to everyone.

```swift
extension ListRef {
    // Empty permission = a legacy/locally-created row we own; treat as
    // editable AND owned so the creator isn't locked out.
    var canEdit: Bool {
        switch permission {
        case "", "owner", "read-write", "writer", "admin": return true
        default: return false
        }
    }
    var isOwner: Bool { permission.isEmpty || permission == "owner" }
}
```

```swift
Button { share(ref) } label: { Label("Share", systemImage: "person.crop.circle.badge.plus") }
if ref.canEdit {
    Button { rename(ref) } label: { Label("Rename", systemImage: "pencil") }
}
if ref.isOwner {
    Button(role: .destructive) { delete(ref) } label: { Label("Delete", systemImage: "trash") }
}
```

Don't gate Delete on `canEdit`: deleting a doc you don't own fails
server-side and the row comes back on the next reconcile.

### 6. Sheets that target an item, not a boolean

When a sheet shows context for "the row the user just acted on," use
`.sheet(item:)` with an `Identifiable` payload, not `.sheet(isPresented:)`
with a separate `@State` for the selection. The boolean form forces a
two-step rebuild every time the selection changes.

```swift
@State private var pendingShare: ShareSheetView.Target?

.sheet(item: $pendingShare) { target in
    ShareSheetView(target: target)
}

// Trigger:
Button { pendingShare = .document(documentId: ref.documentId, title: ref.title) } …
```

Make `Target` `Identifiable` if it isn't already (computed `id` based on
the discriminator + payload id).

### 7. Detail views auto-pop when the open document is deleted

When a detail view opens a document, subscribe to `.documentMetadataChanged`,
gate on `action == "deleted"`, and pop the view on match:

```swift
@State private var deletedSub: EventSubscription?

.task {
    deletedSub = appState.client?.events.on(.documentMetadataChanged) { [weak self] (ev: DocumentMetadataChangedEvent) in
        Task { @MainActor in
            guard let self, ev.action == "deleted", ev.documentId == self.documentId else { return }
            self.dismiss()
        }
    }
}
.onDisappear { deletedSub?.cancel() }
```

`.documentMetadataChanged` fires for every metadata transition — its `action`
is one of `"created"`, `"updated"`, `"deleted"`, or `"evicted"` — so check for
`action == "deleted"` to pop only when this document is actually deleted or
revoked (the server clears the metadata and sends `action == "deleted"` for
both). Without this, deleting a doc on another device (or being unshared)
leaves the user staring at stale data until they navigate away manually.

### 8. Multi-doc apps: openAuxiliaryDoc, not selectDocumentAwaiting

If the app keeps an ambient library/index doc open and opens per-item
docs in detail views, use `appState.openAuxiliaryDoc(_:modelType:)` /
`closeAuxiliaryDoc(_:)`. `selectDocumentAwaiting(_:)` would close the
library doc.

### 9. Forms that take an email

Email-input `TextField`s need a recurring set of modifiers. On iOS:

```swift
TextField("Email address", text: $email)
    #if os(iOS)
    .keyboardType(.emailAddress)
    .textInputAutocapitalization(.never)
    .submitLabel(.send)
    #endif
    .autocorrectionDisabled()
    .onSubmit { submit() }
```

`.autocorrectionDisabled()` is cross-platform; everything else needs the
iOS gate.

### 10. Hierarchical SF Symbol rendering for state-aware icons

Send buttons, checkmarks, toggles — anything that fades when disabled
— should use:

```swift
Image(systemName: "arrow.up.circle.fill")
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(.tint)
```

with `.disabled(condition)` on the parent. Don't ternary the color.

### 11. Reorderable lists by default

If a `List` shows user-owned items that have any meaningful order (todos,
list items, collections, playlist tracks, steps, etc.), make it
drag-to-reorder **unless there's a real reason not to**. iOS users expect
to be able to drag rows; a static list of their own content reads as
unfinished. Wire `.onMove` + persist the new order:

```swift
List {
    ForEach(items) { item in Row(item) }
        .onMove { from, to in reorder(from: from, to: to) }
}
// No EditButton needed on iOS 15+: long-press-drag works in a plain
// List. Add an EditButton only if you also want an explicit edit mode.
```

```swift
// Persist by rewriting the sortOrder field. Use fractional / spaced
// values so a single move is one write, not a full renumber:
func reorder(from: IndexSet, to: Int) {
    var ordered = items
    ordered.move(fromOffsets: from, toOffset: to)
    for (i, item) in ordered.enumerated() {
        model.update(item.id, ["sortOrder": Double(i)])
    }
}
```

The loader's sort closure must order by that same field
(`findAll().sorted { $0.sortOrder < $1.sortOrder }`) so the drag sticks.

**If you add an `EditButton`, also wire `.onDelete`.** `EditButton` toggles
edit mode, which surfaces the `.onMove` drag handles — but with no `.onDelete`,
edit mode is reorder-only and reads as broken: the user taps Edit, sees
grab handles, expects to delete, and can't. Either **drop the `EditButton`**
(long-press-drag reorders, and swipe / context-menu already delete), or
**pair it with `.onDelete`** so edit mode is the conventional reorder + delete.
Don't ship a reorder-only edit mode next to a separate swipe-to-delete — that's
two half-overlapping delete models. Default: no `EditButton`.

**Real reasons to skip** (state the reason if you do): the order is
server-/algorithm-defined (search results, a feed, leaderboard), the list
is read-only / not the user's content, or the sort is an explicit
user-chosen key (alphabetical, by date) where manual order would fight
the chosen sort. A completed-items-sink-to-bottom rule (like a todo list)
is compatible — reorder within the open section, keep the completed
partition.

### 12. Drag items into folders / across sections

If the screen groups items into folders/collections (a "Collections" section
plus loose items, a folder sidebar, etc.), users expect to **drag an item
into a folder** — not just reorder within its current section. Filing only
via a context-menu "Move to…" while the rows visibly drag reads as
half-finished. When you have folder grouping, make drag the primary way to
file:

- Make rows draggable and folder rows (or folder sections) drop targets;
  on drop, update the item's parent field (`collectionId`, `folderId`, …)
  and persist.
- `.draggable(item)` on the row + `.dropDestination(for:)` on the
  collection row / section header is the typical wiring. Dragging an item
  *out* (to the loose/top-level section) clears the parent (`collectionId = ""`).
- Keep a context-menu "Move to…" as a discoverable fallback, but it
  shouldn't be the *only* way to file.

Example: in a todo app with a Collections section and loose lists, dragging
a loose list onto a collection files it there (sets `collectionId`); dragging
it back out to the loose section clears it. Reordering (#11) and filing are
both expected — a list you can reorder but not drag into a visible folder
feels broken.

### 13. Empty & loading states stay pull-to-refreshable

If a screen supports pull-to-refresh, its `.loading` and `.empty` branches
must too. `ContentUnavailableView` / a bare `ProgressView` aren't scrollable,
so `.refreshable` silently does nothing there — the user lands on an empty
screen they can't pull to refresh (common when data arrives via a share from
someone else, since list endpoints aren't reactive — see the swift-client
guide). Wrap non-scrollable placeholders so the gesture works:

```swift
ScrollView { EmptyState() }
    .refreshable { await appState.reconcile() }
// or render the empty placeholder as a row inside the same List.
```

### 14. Never surface raw technical output to users

User-facing strings must read like product copy, never machine output. The
two ways this leaks, both caught in real builds:

- **Unrendered markup.** `Text("^[\(n) item](inflect: true)")` renders the
  literal `^[…]` the moment the string is built by concatenation or as a
  plain `String` (inflection only works on a bare `LocalizedStringKey`).
  Use plain interpolation (`"\(n) item\(n == 1 ? "" : "s")"`) unless you're
  sure it's a bare key literal. Same class: `**bold**`, raw `\n`, enum/case
  names (`.readWrite`), JSON fragments.
- **Raw errors.** Don't pipe `error.localizedDescription` / HTTP status
  codes / server messages straight into a toast or alert. A 403 should read
  "You don't have access to edit this list," not "The operation couldn't be
  completed (… 403)." Treat `catch` as a translation boundary: map the
  error (code → friendly message), then show that.

```swift
// Bad
catch { toast(error.localizedDescription) }          // leaks raw server text
Text("^[\(count) task](inflect: true)" + suffix)     // renders ^[…] literally

// Good
catch { toast(friendlyMessage(for: error)) }         // code → human copy
Text("\(count) task\(count == 1 ? "" : "s")" + suffix)
```

## Verification checklist

Run after every SwiftUI editing session:

- [ ] No raw technical output in user-facing strings — grep the diff for
      `^[`, `localizedDescription` in `Views/**`, and raw HTTP codes; map
      errors to friendly copy in `catch`.
- [ ] Every `NavigationLink` row that owns mutations has `.contextMenu { … }`.
- [ ] No unwrapped iOS-only modifiers (`navigationBarTitleDisplayMode`,
      `textInputAutocapitalization`, `submitLabel`, `keyboardType`,
      `insetGrouped`) — check the grep in rule #2.
- [ ] No `foregroundStyle(cond ? .tint : .secondary)` shape — uses
      `AnyShapeStyle(...)` or `.disabled(...)` + `.hierarchical`.
- [ ] Views with a `BaoDataLoader` render through `switch loader.phase`
      (or gate empty-state on `initialDataLoaded`).
- [ ] Rename/edit gated on `canEdit`; **Delete gated on `isOwner`** (owner
      only — deleting a doc you don't own fails and the row reappears on
      reconcile), not on `canEdit`.
- [ ] Item-targeted sheets use `.sheet(item:)`, not
      `.sheet(isPresented:) + @State selection`.
- [ ] Detail views opening a single doc subscribe to `.documentMetadataChanged` and pop on `action == "deleted"`
      and pop on match.
- [ ] Multi-doc apps use `openAuxiliaryDoc` (NOT `selectDocumentAwaiting`)
      for transient detail-view docs.
- [ ] Email `TextField`s have `.keyboardType(.emailAddress)` +
      `.textInputAutocapitalization(.never)` (iOS-gated) +
      `.autocorrectionDisabled()`.
- [ ] Lists of the user's own ordered content are drag-to-reorder
      (`.onMove` + persisted `sortOrder`) — or there's a stated real
      reason not to (server-defined order, read-only, explicit sort key).
- [ ] No `EditButton` without a matching `.onDelete` (reorder-only edit
      mode reads as broken) — default to no `EditButton`.
- [ ] Screens with folders/collections let you drag an item into a folder
      (update parent field), not just reorder within a section.
- [ ] Pull-to-refresh screens keep `.loading` / `.empty` branches
      refreshable (wrap non-scrollable placeholders in a `ScrollView`).

## When the user pushes back

If the user says "skip the iOS-only gates, I'm not targeting macOS" —
double-check `project.yml`. If it says `platform: [iOS, macOS]`, the
gates are required regardless of intent. Suggest dropping macOS from the
platform list rather than letting unguarded code in.
