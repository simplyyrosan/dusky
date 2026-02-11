Dusky TUI Master Template - Stress Testing Guide

This guide details the specific edge cases implemented in stress_test_extreme.sh and what behaviors you should expect during testing.

1. Tab 0: "The Wall" (Massive List)

Test: Scrolling through 250 items.

Action: Hold j (down) to scroll rapidly.

Expectation: The UI should remain responsive. The scroll indicator ▼ (more below) should update correctly showing [x/250].

Limit Check: Scroll to item #250. Ensure the list stops cleanly and doesn't crash or loop unexpectedly.

2. Tab 1: "The Abyss" (Deep Nesting)

Test: Reading values from level_0 down to level_5.

Logic Check: The engine uses key|immediate_parent_block for lookups.

Action: Modify "Level 6 (Depth 6)".

Expectation: The change should persist in stress_test_extreme.conf. Open the config file in a separate terminal and verify that val_l6 inside level_5 { ... } changes, and that indentation is preserved.

Edge Case: Verify that modifying a deep value doesn't accidentally modify a value with the same name in a shallower scope.

3. Tab 2: "Minefield" (Parser Traps)

Octal Traps (08/09)

Test: "Octal 08 (Trap)" and "Octal 09 (Trap)".

Context: In Bash, numbers starting with 0 are octal. 08 is invalid octal.

Action: Increase value of "Octal 08" (currently 8).

Expectation: It should increment to 9. If the engine fails to sanitize inputs (using 10#...), it will likely crash or error when attempting arithmetic on 08.

Floating Point Precision

Test: "Float Micro" (0.00001).

Action: Increment/Decrement.

Expectation: awk math should handle this correctly. Ensure it doesn't round to 0 unexpectedly.

Test: "Float Negative" (-50.5).

Expectation: Should handle negative signs correctly during read and write.

Missing/Empty Keys

Test: "Explicit Empty" (val_empty).

Expectation: Should show the value (e.g., "one") if set in config, or cycle correctly.

Test: "Missing Key" (val_missing).

Expectation: Should display ⚠ UNSET initially. If you toggle it, it should write the key to the global scope (end of file) because it has no block definition in register.

4. Tab 3: "Menus" (Drill Down)

Test: "Deep Controls >".

Action: Press Enter to open.

Expectation: View switches to the submenu. You should see "Deep Value L5" and "Deep Value L6".

Logic Check: These items actually map to the same variables as in Tab 1 ("The Abyss"). Changing them here should reflect in Tab 1 (when you go back and reload/refresh, though the engine caches values so it might require a restart to see cross-tab updates unless the cache key matches exactly).

5. Tab 4: "Palette" (Hex/Hash parsing)

Test: "Hash NoSpace" (#aabbcc).

Expectation: Should display #aabbcc.

Test: "Hash Space (Trap)" (#ddeeff).

Context: The config file has col_hash_space = #ddeeff.

Trap: The engine parser regex sub(/[[:space:]]+#.*$/, "", val) treats  #... as a comment.

Expectation: This value will likely appear as ⚠ UNSET or empty because the parser strips the value thinking it's a comment. This is expected behavior for the current regex logic. If you modify it, it will likely write col_hash_space = #newhex (potentially losing the space if the writer is strict, or keeping it).

6. Tab 5: "Void" (Empty Tab)

Test: Switch to this tab.

Expectation: The UI should display an empty list. It should not crash. Scrolling keys should do nothing.

General Parser Robustness

Braces in Comments: The config file contains # { ignore_me = true }.

Expectation: The parser's brace counting logic must ignore these. If it fails, the nesting depth of subsequent blocks (like traps or colors) will be wrong, and values won't load. If Tab 2 or Tab 4 items are ⚠ UNSET, the brace counting logic failed.
