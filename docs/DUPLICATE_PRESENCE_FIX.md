# Duplicate Presence Entries Fix

## Problem
When a user refreshes their browser window, they would see duplicate entries in the "In Session" list:
- Standard Clerk (You)
- Standard Clerk clerk
- Standard Clerk clerk
- Standard Clerk clerk

This happened because:
1. Each LiveView connection gets a unique `peer_id` (e.g., `bMiqP8ql`)
2. When refreshing, a new LiveView process starts with a new `peer_id`
3. The old LiveView process terminates, but Phoenix Presence cleanup has a small delay
4. During this race condition window, both the old and new `peer_id` exist in Presence
5. The template displayed all peer_ids, showing the same user multiple times

## Solution
Implemented **client-side deduplication** by `user_id` in the LiveView:

### Changes Made

1. **Added `user_id` to Presence metadata** (`lib/judiciary_web/live/activity_live/room.ex`)
   - Now tracks: `user_id`, `display_name`, `role`, `status`, `online_at`
   - This allows grouping peers by actual user instead of connection

2. **Created `deduplicate_peers_by_user/2` helper function**
   - Groups peers by `user_id` (or fallback to `display_name + role`)
   - Keeps only the most recent peer (highest `online_at` timestamp)
   - Returns deduplicated map for template rendering

3. **Applied deduplication in two places**
   - `mount/3`: Deduplicates initial peer list on page load
   - `handle_info/2` (presence_diff): Deduplicates on every presence update

### How It Works

```elixir
# Before: Multiple peer_ids for same user
%{
  "bMiqP8ql" => %{metas: [%{user_id: 1, display_name: "Standard Clerk", ...}]},
  "AojObGK3" => %{metas: [%{user_id: 1, display_name: "Standard Clerk", ...}]},
  "XyZ123Ab" => %{metas: [%{user_id: 1, display_name: "Standard Clerk", ...}]}
}

# After: One peer_id per user (most recent)
%{
  "XyZ123Ab" => %{metas: [%{user_id: 1, display_name: "Standard Clerk", ...}]}
}
```

### Why This Approach?

**Alternative considered:** Explicit `Presence.untrack/3` in `terminate/2`
- Phoenix Presence already auto-cleanups on process termination
- Adding explicit untrack could cause race conditions
- The real issue is the timing window, not missing cleanup

**Chosen approach benefits:**
- No changes to Presence lifecycle (uses built-in auto-cleanup)
- Handles all race conditions (refresh, network issues, crashes)
- Works even if multiple tabs are open (shows most recent connection)
- Simple, predictable behavior for users

## Testing

1. Log in as any user (e.g., `clerk@judiciary.go.ke`)
2. Join a room
3. Refresh the browser multiple times rapidly
4. Check "In Session" list - should show each user only once
5. Check browser console - no errors
6. Check server logs - presence tracking working correctly

## Files Modified

- `lib/judiciary_web/live/activity_live/room.ex`
  - Added `user_id` to Presence.track metadata
  - Added `user_id` to Presence.update metadata
  - Created `deduplicate_peers_by_user/2` helper
  - Applied deduplication in mount and presence_diff handler
  - Fixed unused variable warnings

## Related Issues

- Fixes: "when i refresh a window i get Standard Clerk (You)...Standard Clerk clerk Standard Clerk clerk..."
- Related to: Phoenix Presence auto-cleanup timing
- No changes needed in: `lib/judiciary_web/presence.ex` (uses default Phoenix.Presence)
