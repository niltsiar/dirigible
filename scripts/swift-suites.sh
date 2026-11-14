# The awk text that reads the suites of the Swift test files. scripts/test-filter.sh and
# scripts/check-changed.sh source this file, so both read the same parser.
# decl_awk: the awk function decl(line) returns the type name of a top-level struct, class, enum,
# actor, or extension line at column 0 (attributes and modifiers can come first) and sets kind.
# suite_awk prints each type with a @Test in a top-level block. A block runs from its declaration
# line to the next declaration line or a line that starts with }.
# With awk -v slow=skip, a @Test whose traits hold DIRIGIBLE_SLOW_TESTS does not count, because
# test-filter.sh refuses a name whose tests all skip. The parser reads the gate on the @Test line,
# or on a later line before the trait parentheses of the @Test close (`@Test(` and then
# `.enabled(if: ...)` on the next line). A gate in a test body or in a @Suite trait does not count.
# file_awk prints "D <type>" or "E <type>" for each declaration or extension line.
# scripts/check-changed.test.sh and scripts/test-filter.test.sh test it.
decl_awk='function decl(l,   n, w) {
    kind = ""
    if (!match(l, "^((@[A-Za-z_][A-Za-z0-9_]*(\\([^)]*\\))?|public|internal|private|fileprivate|final|open)[ \t]+)*(struct|class|enum|actor|extension)[ \t]+[A-Za-z_][A-Za-z0-9_.]*")) return ""
    n = split(substr(l, RSTART, RLENGTH), w, /[ \t]+/)
    kind = w[n - 1]
    return w[n]
}'
suite_awk='function parens(l,   o) { o = gsub(/\(/, "", l); return o - gsub(/\)/, "", l) }
FNR == 1 { cur = ""; held = "" }
{
    if (held != "") {
        if ($0 ~ /DIRIGIBLE_SLOW_TESTS/) held = ""
        else if ((depth += parens($0)) <= 0) { suite[held] = 1; held = "" }
    }
    d = decl($0)
    if (d != "") cur = d
    if (cur != "" && $0 !~ /^[ \t]*\/\// && $0 ~ /@Test([^A-Za-z0-9_]|$)/) {
        if (slow != "skip") suite[cur] = 1
        else if ($0 !~ /DIRIGIBLE_SLOW_TESTS/) {
            depth = parens(substr($0, index($0, "@Test")))
            if (depth > 0) held = cur
            else suite[cur] = 1
        }
    }
    if (d != "" && $0 ~ /\{.*\}[ \t]*$/) cur = ""
    else if ($0 ~ /^\}/) cur = ""
}
END { for (s in suite) print s }'
file_awk='{ d = decl($0); if (d != "") print (kind == "extension" ? "E " : "D ") d }'
