// uci.uc — чистые строковые хелперы для diff'а UCI-списков (doh.uc). Не desired-state движок —
// см. [[reliability]].

// starts_with(s, prefix) — true, если строка s начинается с prefix.
function starts_with(s, prefix) {
	return length(s) >= length(prefix) && substr(s, 0, length(prefix)) == prefix;
}

export { starts_with };
