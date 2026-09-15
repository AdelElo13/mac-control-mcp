# Migration notes — 0.10 accessibility search

## Role filters now match exact normalized names

`find_element` and `find_elements` now match roles by case-insensitive equality, with an optional `AX` prefix. `role:"Button"` and `role:"AXButton"` both match only `AXButton`. They no longer also match `AXRadioButton`, `AXMenuButton`, or `AXPopUpButton`.

For the previous broad role search, use `query_elements` with `role_regex:"Button"`. To select an explicit set, use an anchored expression such as `role_regex:"^AX(Button|RadioButton)$"`. `query_elements` retains regular-expression matching for roles.

## Exact matches can end a search early

Without `semantic`, search maintains the ranked top `limit` among visited nodes. It stops when `limit` non-menu matches satisfy all supplied title and value filters exactly. Role-only matches already have this quality. With `interactive_only` or `viewport_only`, only candidates passing those filters count toward the limit and early exit; ineligible containers are still traversed. `find_element` uses `limit=1`, so its first exact non-menu hit ends the walk.

This shortcut does not compare later, equally exact matches: a smaller or more interactive control later in the tree can be missed. Use `query_elements` with anchored role/label expressions when these global tie-breaks matter. Its ranking still covers only the nodes reached within the depth, 5000-node and five-second limits.

Semantic targets, menu-only matches and searches without enough exact hits continue through the bounded tree. Prefix/substring hits remain ranked instead of being returned in depth-first order. A menu match never triggers early exit, because an equivalent window control may occur later.

`nodes_visited` now counts actual node reads. `search_stopped_early` distinguishes the exact-hit shortcut in `find_element`/`find_elements`; `truncated` reports a node/time or payload budget stopping the search. An early exact match is not a budget truncation.
