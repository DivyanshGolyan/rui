// Package bashresult validates complete stored-byte Bash result frames for qualification fixtures.
package bashresult

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// Body binds all five stored-byte spans before inspecting status or markers.
func Body(output string) (string, bool) {
	header, body, ok := strings.Cut(output, "\n")
	const prefix = "RUI-BASH-RESULT/1 "
	if !ok || !strings.HasPrefix(header, prefix) {
		return "", false
	}
	fields := strings.Split(strings.TrimPrefix(header, prefix), " ")
	if len(fields) != 5 {
		return "", false
	}
	remaining := uint64(len(body))
	for _, field := range fields {
		if field == "" {
			return "", false
		}
		for _, digit := range field {
			if digit < '0' || digit > '9' {
				return "", false
			}
		}
		length, err := strconv.ParseUint(field, 10, 64)
		if err != nil || length > remaining {
			return "", false
		}
		offset := uint64(len(body)) - remaining
		if !utf8.ValidString(body[offset : offset+length]) {
			return "", false
		}
		remaining -= length
	}
	return body, remaining == 0
}
