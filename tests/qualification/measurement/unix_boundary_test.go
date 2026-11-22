package measurement

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// unixSocketCalls are the net functions that open an AF_UNIX socket when they name "unix"
// as the network. ListenUnix and DialUnix always do, so they match without a literal.
var unixSocketCalls = map[string]bool{
	"Listen": true, "ListenUnix": true, "Dial": true, "DialTimeout": true, "DialUnix": true,
}

// unixOwnerCalls are the only calls allowed to open a Unix socket: the measurement package's
// owners. Their bodies are the one place that checks the 104-byte path (#1948).
var unixOwnerCalls = map[string]bool{"ListenUnix": true, "DialUnix": true}

// unixBoundaryScan reports every Unix socket call in one parsed file that is not inside a
// measurement owner, and counts the owner calls it found. Only literal "unix" networks are
// matched for Listen, Dial and DialTimeout; a network held in a variable is not seen.
func unixBoundaryScan(fset *token.FileSet, file *ast.File, path string) (violations []string, owned int) {
	ownerFile := filepath.Base(path) == "measurement.go" && filepath.Base(filepath.Dir(path)) == "measurement"
	for _, decl := range file.Decls {
		function, isFunc := decl.(*ast.FuncDecl)
		inOwner := ownerFile && isFunc && unixOwnerCalls[function.Name.Name]
		ast.Inspect(decl, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			selector, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || !unixSocketCalls[selector.Sel.Name] {
				return true
			}
			name := selector.Sel.Name
			if name != "ListenUnix" && name != "DialUnix" && !(len(call.Args) > 0 && isUnixLiteral(call.Args[0])) {
				return true
			}
			if inOwner || isOwnerCall(selector) {
				owned++
				return true
			}
			violations = append(violations, fmt.Sprintf("%s: %s opens a Unix socket outside the measurement owners ListenUnix and DialUnix",
				fset.Position(call.Pos()), name))
			return true
		})
	}
	return violations, owned
}

// isOwnerCall reports measurement.ListenUnix and measurement.DialUnix, the owners as other
// packages reach them.
func isOwnerCall(selector *ast.SelectorExpr) bool {
	receiver, ok := selector.X.(*ast.Ident)
	return ok && receiver.Name == "measurement" && unixOwnerCalls[selector.Sel.Name]
}

func isUnixLiteral(expression ast.Expr) bool {
	literal, ok := expression.(*ast.BasicLit)
	if !ok || literal.Kind != token.STRING {
		return false
	}
	value, err := strconv.Unquote(literal.Value)
	return err == nil && value == "unix"
}

// TestUnixSocketCallsStayInTheMeasurementOwners walks every Go file in tests/qualification
// and refuses a Unix socket call outside ListenUnix or DialUnix (#1948).
func TestUnixSocketCallsStayInTheMeasurementOwners(t *testing.T) {
	var violations []string
	owned, files := 0, 0
	fset := token.NewFileSet()
	err := filepath.WalkDir("..", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(path) != ".go" {
			return nil
		}
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		file, err := parser.ParseFile(fset, path, source, 0)
		if err != nil {
			return err
		}
		files++
		found, count := unixBoundaryScan(fset, file, path)
		violations = append(violations, found...)
		owned += count
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if files < 10 || owned < 2 {
		t.Fatalf("scan saw %d Go files and %d owner calls; expected the whole qualification tree and both owners", files, owned)
	}
	if len(violations) > 0 {
		t.Fatalf("Unix socket calls outside the owners:\n%s", strings.Join(violations, "\n"))
	}
}

// TestUnixSocketScanRefusesACallOutsideTheOwners plants violations and an owner call in
// fixture sources, so the scan is shown to refuse what it claims to refuse.
func TestUnixSocketScanRefusesACallOutsideTheOwners(t *testing.T) {
	parse := func(path, source string) (*token.FileSet, *ast.File) {
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, source, 0)
		if err != nil {
			t.Fatal(err)
		}
		return fset, file
	}
	fixture := `package fixture

import (
	"net"
	"time"
)

func leak(path string) {
	net.DialTimeout("unix", path, time.Second)
	net.ListenUnix("unix", nil)
	net.Listen("unix", path)
	dialer := net.Dialer{}
	dialer.Dial("unix", path)
	net.Dial("tcp", "127.0.0.1:1")
	net.Listen("tcp4", "127.0.0.1:0")
}
`
	fset, file := parse("model-control/fixture.go", fixture)
	violations, owned := unixBoundaryScan(fset, file, "model-control/fixture.go")
	if owned != 0 || len(violations) != 4 {
		t.Fatalf("planted fixture: %d violations and %d owner calls, want 4 and 0:\n%s", len(violations), owned, strings.Join(violations, "\n"))
	}

	owner := `package measurement

import "net"

func DialUnix(path string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("unix", path, timeout)
}

func ListenUnix(path string) (*net.UnixListener, error) {
	return net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
}

func retireSocket(path string) {
	net.DialTimeout("unix", path, 0)
}
`
	fset, file = parse("tests/qualification/measurement/measurement.go", owner)
	violations, owned = unixBoundaryScan(fset, file, "tests/qualification/measurement/measurement.go")
	if owned != 2 || len(violations) != 1 {
		t.Fatalf("owner fixture: %d owner calls and %d violations, want 2 and 1 (retireSocket is not an owner):\n%s",
			owned, len(violations), strings.Join(violations, "\n"))
	}
	if !strings.Contains(violations[0], "DialTimeout") {
		t.Fatalf("violation does not name the call: %s", violations[0])
	}
}
