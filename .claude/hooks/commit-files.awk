# Shared by git-guardrails.sh (a Bash command) and agent-guard.sh (the text of a brief, with -v brief=1).
# For each git commit of the input lines, print one line:
# - the value of the message-file option, read up to the first ; & | , or sentence end outside quotes.
#   The option is -F in a short-option cluster that ends in F (-aF, -Fmsg.txt), or --fil or --file with
#   = or a space. A lone quote value is the end of a quoted text and passes; a quote after a space
#   opens the value;
# - \001 for a commit with more than one such option, because git reads the last one;
# - \002 for -F - whose stdin is a file redirect (< file), the right side of a pipe, or (a Bash
#   command only) no heredoc, because the file can belong to another work tree.
# Text inside a quoted string is data: a git commit or an option that starts inside one is skipped.
# In $'...' a backslash escapes the next character. The quote state runs over the lines of a Bash
# command (a quoted message can span lines) and ends at the end line of each heredoc. In a Bash
# command an & that is part of a redirect (2>&1, >&2, &>) does not end the chunk. In a brief a quote
# opens only after a non-word character and when a closing quote follows on the line, so an apostrophe
# in prose opens none; a quote that holds git commit is data only when a search word (rg, grep, find,
# ag, git log -S) comes before it on the line, so a quoted instruction is read. There the chunk of a
# commit in inline code ends at the closing backtick. Misses: a commit that a shell runs from a quoted
# string (bash -c, eval, $(...)).
BEGIN { search = "(^|[^A-Za-z0-9_-])(rg|grep|find|ag|git log -S)([^A-Za-z0-9_]|$)" }
# closes(line, k): the index of the closing quote of the quote that opens at k, or 0.
function closes(line, k,   c, j, n) {
  c = substr(line, k, 1); n = length(line)
  for (j = k + 1; j <= n; j++) {
    if (c == "\"" && substr(line, j, 1) == "\\") { j++; continue }
    if (substr(line, j, 1) == c && substr(line, j + 1, 1) !~ /[A-Za-z0-9]/) return j
  }
  return 0
}
# mark(line): inq[k] is 1 for each character inside a quoted string of the line.
function mark(line,   n, k, c, e, dollar) {
  n = length(line)
  for (k = 1; k <= n; k++) inq[k] = 0
  if (brief) q = ""
  for (k = 1; k <= n; k++) {
    c = substr(line, k, 1)
    if (q != "") {
      if ((q == "\"" || ansi) && c == "\\") { inq[k] = 1; if (++k <= n) inq[k] = 1 }
      else if (c == q && (!brief || substr(line, k + 1, 1) !~ /[A-Za-z0-9]/)) q = ""
      else inq[k] = 1
      dollar = 0
    }
    else if (c == "\\" && !brief) { k++; dollar = 0 }
    else if ((c == "\"" || c == "\047") && (!brief || (substr(line, k - 1, 1) !~ /[A-Za-z0-9]/ && (e = closes(line, k)) &&
        (substr(line, 1, k - 1) ~ search || substr(line, k + 1, e - k - 1) !~ /git commit/)))) {
      q = c; ansi = (c == "\047" && dollar); dollar = 0
    }
    else dollar = (c == "$")
  }
}
# heredocs(line): remember the end marker of each heredoc that the line opens (<<MARK, <<-MARK, <<'MARK').
function heredocs(line,   s, base, at, m, dash) {
  s = line; base = 0
  while (match(s, /<<-?[ \t]*(\\?[A-Za-z0-9_.-]+|\047[A-Za-z0-9_.-]+\047|"[A-Za-z0-9_.-]+")/)) {
    at = base + RSTART; m = substr(s, RSTART, RLENGTH)
    base += RSTART + RLENGTH - 1; s = substr(s, RSTART + RLENGTH)
    if (inq[at] || substr(line, at - 1, 1) == "<") continue
    dash = (substr(m, 3, 1) == "-")
    gsub(/^<<-?[ \t]*[\\\047"]?|[\047"]$/, "", m)
    hdash[++hn] = dash; hmark[hn] = m
  }
}
{
  line = $0
  if (!brief) {
    for (h = 1; h <= hn; h++) {
      t = line
      if (hdash[h]) sub(/^[ \t]+/, "", t)
      if (t != hmark[h]) continue
      for (hn--; h <= hn; h++) { hdash[h] = hdash[h + 1]; hmark[h] = hmark[h + 1] }
      q = ""
    }
  }
  mark(line)
  if (!brief) heredocs(line)
  base = 0; s = line
  while ((i = index(s, "git commit")) > 0) {
    at = base + i; c0 = at + 10
    base = at + 9; s = substr(s, i + 10)
    if (inq[at]) continue
    chunk = s
    if ((j = index(s, "git commit")) > 0) chunk = substr(s, 1, j - 1)
    pre = substr(line, 1, at - 1)
    copy = pre
    ticks = gsub(/`/, "", copy)
    for (k = 1; k <= length(chunk); k++) {
      c = substr(chunk, k, 1)
      if (inq[c0 + k - 1]) continue
      if (c == "&" && !brief && (substr(chunk, k - 1, 1) ~ /[<>]/ || substr(chunk, k + 1, 1) == ">")) continue
      if (c ~ /[;&|,]/ || (c == "." && substr(chunk, k + 1, 1) == " ") || (brief && ticks % 2 == 1 && c == "`")) {
        chunk = substr(chunk, 1, k - 1); break
      }
    }
    n = 0; rest = chunk; off = 0
    while (match(rest, /(^| )(-[a-zA-EG-Z]*F ?|--fil(e)?[= ])[^ ]+/)) {
      t = substr(rest, RSTART, RLENGTH)
      st = off + RSTART + (substr(t, 1, 1) == " ")
      off += RSTART + RLENGTH - 1
      rest = substr(rest, RSTART + RLENGTH)
      if (inq[c0 + st - 1]) continue
      v = t
      sub(/^ ?(-[a-zA-EG-Z]*F ?|--fil(e)?[= ])/, "", v)
      if ((v == "\"" || v == "\047") && substr(t, length(t) - 1, 1) == " " && (e = index(rest, v)) > 0) {
        v = v substr(rest, 1, e)
        rest = substr(rest, e + 1)
        off += e
      }
      if (++n == 1) first = v
    }
    if (n > 1) print "\001"
    else if (n == 1 && first != "-") print first
    else if (n == 1) {
      u = ""
      for (k = 1; k <= length(chunk); k++) u = u (inq[c0 + k - 1] ? "x" : substr(chunk, k, 1))
      here = (u ~ /<</)
      gsub(/<<<?-?/, "", u)
      if (pre ~ /(^|[^|])\|[ ]*$/ || u ~ /</ || (!brief && !here)) print "\002"
      else print "-"
    }
  }
}
