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
# The quote state runs over the lines of a Bash command (a quoted message can span lines). In a brief
# a quote opens only after a non-word character and when a closing quote follows on the line, so an
# apostrophe in prose opens none; there the chunk of a commit in inline code ends at the closing
# backtick. Misses: a commit that a shell runs from a quoted string (bash -c, eval, $(...)), and a
# commit after an apostrophe in the body of an interpreter heredoc, which the caller keeps as code.
function closes(line, k,   c, j, n) {
  c = substr(line, k, 1); n = length(line)
  for (j = k + 1; j <= n; j++) {
    if (c == "\"" && substr(line, j, 1) == "\\") { j++; continue }
    if (substr(line, j, 1) == c && substr(line, j + 1, 1) !~ /[A-Za-z0-9]/) return 1
  }
  return 0
}
# mark(line): inq[k] is 1 for each character inside a quoted string of the line.
function mark(line,   n, k, c) {
  n = length(line)
  for (k = 1; k <= n; k++) inq[k] = 0
  if (brief) q = ""
  for (k = 1; k <= n; k++) {
    c = substr(line, k, 1)
    if (q != "") {
      if (q == "\"" && c == "\\") { inq[k] = 1; if (++k <= n) inq[k] = 1 }
      else if (c == q && (!brief || substr(line, k + 1, 1) !~ /[A-Za-z0-9]/)) q = ""
      else inq[k] = 1
    }
    else if (c == "\\" && !brief) k++
    else if ((c == "\"" || c == "\047") && (!brief || (substr(line, k - 1, 1) !~ /[A-Za-z0-9]/ && closes(line, k)))) q = c
  }
}
{
  line = $0
  mark(line)
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
