package measurement

import (
	"reflect"
	"strings"
	"testing"
)

const instructionSource = `pub const BuiltinInstructions = enum {
    generic,
    first,
    second,

    pub fn bytes(self: BuiltinInstructions) []const u8 {
        return switch (self) {
            .generic => "",
            .first, .second => @embedFile("model_instructions/shared.txt"),
        };
    }
};

pub fn builtinInstructions(model: []const u8) BuiltinInstructions {
    const reviewed = .{
        .{ "fixture-model", BuiltinInstructions.first },
        .{ "other-model", BuiltinInstructions.second },
    };
    inline for (reviewed) |entry| if (std.mem.eql(u8, model, entry[0])) return entry[1];
    return .generic;
}
`

func TestInstructionPathsFollowCatalogSource(t *testing.T) {
	for _, test := range []struct {
		source string
		want   map[string]string
	}{
		{instructionSource, map[string]string{"fixture-model": "model_instructions/shared.txt", "other-model": "model_instructions/shared.txt"}},
		{strings.ReplaceAll(strings.ReplaceAll(instructionSource, `"fixture-model"`, `"new-model"`), "shared.txt", "changed.txt"), map[string]string{"new-model": "model_instructions/changed.txt", "other-model": "model_instructions/changed.txt"}},
		{strings.ReplaceAll(instructionSource, `        .{ "other-model", BuiltinInstructions.second },`, ""), map[string]string{"fixture-model": "model_instructions/shared.txt"}},
	} {
		got, err := instructionPaths(test.source)
		if err != nil || !reflect.DeepEqual(got, test.want) {
			t.Fatalf("catalog selection: got %v, %v; want %v", got, err, test.want)
		}
	}
}

func TestInstructionPathsRejectUnsupportedSource(t *testing.T) {
	for _, change := range [][2]string{
		{"BuiltinInstructions = enum", "BuiltinInstructions = struct"},
		{"return switch (self)", "return switch (other)"},
		{`.generic => ""`, `.generic => @embedFile("model_instructions/shared.txt")`},
		{".first, .second =>", ".first =>"},
		{"    second,", "    first,"},
		{".first, .second =>", ".first, .second, .missing =>"},
		{"shared.txt", "../shared.txt"},
		{"BuiltinInstructions.second },", "BuiltinInstructions.missing },"},
		{`"other-model"`, `"fixture-model"`},
		{"return entry[1]", "return .generic"},
		{"return .generic;", "return .first;"},
		{"    const reviewed", "    // unsupported shape\n    const reviewed"},
	} {
		t.Run(change[0], func(t *testing.T) {
			if _, err := instructionPaths(strings.ReplaceAll(instructionSource, change[0], change[1])); err == nil || !strings.Contains(err.Error(), "src/model_catalog.zig") {
				t.Fatalf("unsupported source was not rejected clearly: %v", err)
			}
		})
	}
	for _, source := range []string{
		"", instructionSource + instructionSource,
		strings.ReplaceAll(instructionSource, `            .generic => "",`, ""),
		strings.ReplaceAll(strings.ReplaceAll(instructionSource, `        .{ "fixture-model", BuiltinInstructions.first },`, ""), `        .{ "other-model", BuiltinInstructions.second },`, ""),
	} {
		if _, err := instructionPaths(source); err == nil || !strings.Contains(err.Error(), "src/model_catalog.zig") {
			t.Fatalf("unsupported source was not rejected clearly: %v", err)
		}
	}
}
