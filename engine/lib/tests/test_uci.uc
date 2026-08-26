// test_uci.uc — юнит-тесты чистых UCI-хелперов.
//   ucode -R engine/lib/tests/test_uci.uc

import { test, ok, summary } from "../assert.uc";
import { starts_with } from "../uci.uc";

test("starts_with", () => {
	ok(starts_with("127.0.0.1#5053", "127.0.0.1#"));
	ok(!starts_with("8.8.8.8", "127.0.0.1#"));
	ok(!starts_with("ab", "abc"));
});

exit(summary());
