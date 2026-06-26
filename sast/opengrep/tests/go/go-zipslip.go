// Regression fixture for security.go-zipslip-archive-path-traversal.
package fixture

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
)

func vulnerable(r *zip.Reader, dst string) {
	for _, f := range r.File {
		// ruleid: security.go-zipslip-archive-path-traversal
		path := filepath.Join(dst, f.Name)
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
	}
}

func guarded(r *zip.Reader, dst string) {
	for _, f := range r.File {
		if strings.Contains(f.Name, "..") {
			continue
		}
		// ok: security.go-zipslip-archive-path-traversal
		path := filepath.Join(dst, f.Name)
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
	}
}
