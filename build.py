"""Apply the QR update to the verified CBIT Customer Toolkit rc15 ZIP."""
import hashlib
import sys
from copy import copy
from pathlib import Path
from tempfile import NamedTemporaryFile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT / "package"
PREFIX = "CBIT-CustomerToolkit-0.3.4/"
BASE_SHA256 = "9bbda060c29593bd7c1165822e991dd758bbabf41bcbb922738e2b3b542e5b6f"


def build(baseline):
    output = ROOT / "dist" / "CBIT-CustomerToolkit-0.3.4.zip"
    if baseline.resolve() == output:
        raise ValueError("Keep the rc15 input ZIP separate from the build output.")
    updates = {
        PREFIX + path.relative_to(PACKAGE).as_posix(): path
        for path in PACKAGE.rglob("*") if path.is_file()
    }
    with baseline.open("rb") as source:
        if hashlib.sha256(source.read()).hexdigest() != BASE_SHA256:
            raise ValueError("Expected the original v0.3.4-rc15 release ZIP.")
        source.seek(0)
        output.parent.mkdir(exist_ok=True)
        with NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
            staged = Path(temporary.name)
        try:
            with ZipFile(source) as before, ZipFile(staged, "w") as after:
                for entry in before.infolist():
                    replacement = updates.pop(entry.filename, None)
                    data = replacement.read_bytes() if replacement else before.read(entry)
                    after.writestr(copy(entry), data)
                for name, path in sorted(updates.items()):
                    after.writestr(ZipInfo(name), path.read_bytes(), compress_type=ZIP_DEFLATED)
            staged.replace(output)
        finally:
            staged.unlink(missing_ok=True)
    return output


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python build.py PATH_TO_ORIGINAL_RC15_ZIP")
    result = build(Path(sys.argv[1]))
    print(f"{result}\nSHA256 {hashlib.sha256(result.read_bytes()).hexdigest()}")
