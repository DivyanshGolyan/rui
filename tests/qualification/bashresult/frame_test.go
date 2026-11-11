package bashresult

import (
	"fmt"
	"testing"
)

func frame(body string) string {
	return fmt.Sprintf("RUI-BASH-RESULT/1 %d 0 0 0 0\n%s", len(body), body)
}

func TestBashResultFrameRequiresExactStoredBytes(t *testing.T) {
	body := "Bash succeeded. Exit code: 0.\nstdout tail:\né中\n"
	framed := frame(body)
	if got, ok := Body(framed); !ok || got != body {
		t.Fatalf("valid frame: %q %v", got, ok)
	}
	for _, bad := range []string{body, framed + "x", framed[:len(framed)-1], "RUI-BASH-RESULT/1 0 0 0 0 18446744073709551615\nx", "RUI-BASH-RESULT/1 +1 0 0 0 0\nx", "RUI-BASH-RESULT/2 0 0 0 0 0\n"} {
		if _, ok := Body(bad); ok {
			t.Fatalf("accepted invalid frame %q", bad)
		}
	}
}

func TestAllFiveSpansAndUTF8Boundaries(t *testing.T) {
	body := "preé中sep🙂foot"
	valid := fmt.Sprintf("RUI-BASH-RESULT/1 %d %d %d %d %d\n%s", len("pre"), len("é中"), len("sep"), len("🙂"), len("foot"), body)
	if got, ok := Body(valid); !ok || got != body {
		t.Fatalf("five spans: %q %v", got, ok)
	}
	for _, bad := range []string{
		"RUI-BASH-RESULT/1 0 0 0 0\n",
		"RUI-BASH-RESULT/1 0 0 0 0 0 0\n",
		"RUI-BASH-RESULT/1 0  0 0 0\n",
		"RUI-BASH-RESULT/1 0 -1 0 0 0\n",
		"RUI-BASH-RESULT/1 1 1 0 0 0\né",
		"RUI-BASH-RESULT/1 1 0 0 0 0\n\xff",
		"RUI-BASH-RESULT/1 0 0 0 0 18446744073709551616\n",
	} {
		if _, ok := Body(bad); ok {
			t.Fatalf("accepted invalid spans %q", bad)
		}
	}
	if got, ok := Body("RUI-BASH-RESULT/1 0 0 0 0 0\n"); !ok || got != "" {
		t.Fatalf("empty spans: %q %v", got, ok)
	}
}
