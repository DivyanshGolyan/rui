package measurement

import (
	"fmt"
	"regexp"
	"strings"
)

func instructionPaths(source string) (map[string]string, error) {
	unsupported := func(part string) error {
		return fmt.Errorf("src/model_catalog.zig: unsupported built-in instruction %s", part)
	}
	block := func(pattern string) (string, error) {
		matches := regexp.MustCompile(pattern).FindAllStringSubmatch(source, -1)
		if len(matches) != 1 {
			return "", unsupported("shape")
		}
		return matches[0][1], nil
	}
	rows := func(pattern, text string) ([][]string, error) {
		expression := regexp.MustCompile(pattern)
		matches := expression.FindAllStringSubmatch(text, -1)
		if len(matches) == 0 || strings.TrimSpace(expression.ReplaceAllString(text, "")) != "" {
			return nil, unsupported("rows")
		}
		return matches, nil
	}
	enum, err := block(`(?ms)^pub const BuiltinInstructions = enum \{\n(.*?)^};$`)
	if err != nil {
		return nil, err
	}
	shape := regexp.MustCompile(`(?s)^\s*((?:\w+,\s*)+)pub fn bytes\(self: BuiltinInstructions\) \[\]const u8 \{\s*return switch \(self\) \{(.*?)\};\s*}\s*$`).FindStringSubmatch(enum)
	if shape == nil {
		return nil, unsupported("bytes")
	}
	tags := regexp.MustCompile(`\w+`).FindAllString(shape[1], -1)
	bodies := map[string]string{}
	bodyRows, err := rows(`((?:\.\w+\s*,\s*)*\.\w+)\s*=>\s*(?:""|@embedFile\("(model_instructions/[\w-]+\.txt)"\)),`, shape[2])
	if err != nil {
		return nil, err
	}
	for _, row := range bodyRows {
		for _, tag := range regexp.MustCompile(`\.(\w+)`).FindAllStringSubmatch(row[1], -1) {
			if _, exists := bodies[tag[1]]; exists {
				return nil, unsupported("duplicate variant")
			}
			bodies[tag[1]] = row[2]
		}
	}
	declared := map[string]bool{}
	for _, tag := range tags {
		if _, exists := bodies[tag]; !exists || declared[tag] {
			return nil, unsupported("variants")
		}
		declared[tag] = true
	}
	generic, exists := bodies["generic"]
	if len(declared) != len(bodies) || !exists || generic != "" {
		return nil, unsupported("variants")
	}
	selector, err := block(`(?ms)^pub fn builtinInstructions\(model: \[\]const u8\) BuiltinInstructions \{\n(.*?)^}$`)
	if err != nil {
		return nil, err
	}
	shape = regexp.MustCompile(`(?s)^\s*const reviewed = \.\{(.*?)\};\s*inline for \(reviewed\) \|entry\| if \(std\.mem\.eql\(u8, model, entry\[0\]\)\) return entry\[1\];\s*return \.generic;\s*$`).FindStringSubmatch(selector)
	if shape == nil {
		return nil, unsupported("selector")
	}
	selections, err := rows(`\.\{ "([^"\\]+)", BuiltinInstructions\.(\w+) },`, shape[1])
	if err != nil {
		return nil, err
	}
	paths := map[string]string{}
	for _, selection := range selections {
		model, tag := selection[1], selection[2]
		path, exists := bodies[tag]
		if _, duplicate := paths[model]; duplicate || !exists {
			return nil, unsupported("selection")
		}
		paths[model] = path
	}
	return paths, nil
}
