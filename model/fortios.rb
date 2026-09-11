# Local override of the stock Oxidized fortios model.
# Difference: SSH runs each command in an exec channel (no PTY, no pager),
# which fetches large FortiGate configs in seconds instead of minutes.
# Per-device opt-out: vars: { ssh_no_exec: true } (e.g. for Telnet-only or odd units).
class FortiOS < Oxidized::Model
  using Refinements

  comment "# "

  prompt /^(\(\w\) )?([-\w.~()]+(\s[(\w\-.)]+)?~?\s?[#>$]\s?)$/

  # When a post-login-banner is enabled, you have to press "a" to log in
  expect /^\(Press\s'a'\sto\saccept\):/ do |data, re|
    send "a"
    data.sub re, ""
  end

  expect /^--More--\s$/ do |data, re|
    send " "
    data.sub re, ""
  end

  cmd :all do |cfg|
    # Remove junk after --More-- pager
    cfg = cfg.gsub(/\r +\r/, "")
    # Remove \r\n after command echo
    cfg = cfg.gsub("\r\n", "\n")
    if screenscrape
      # interactive shell: drop command echo (first line) and prompt (last line)
      cfg = cfg.cut_both
    else
      # exec channel: FortiOS still prints its prompt before the first line and after the last
      cfg = cfg.sub(/\A[^\n]*?[#$>] /, "")
      cfg = cfg.sub(/\n[^\n]*[#$>] ?\z/, "\n")
    end
    cfg
  end

  cmd :secret do |cfg|
    cfg.gsub! /^(\#private-encryption-key=).+/, '\\1 <configuration removed>'
    cfg.gsub! /(set .+ ENC) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set .*secret) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set (?:passwd|password|key|group-password|auth-password-l1|auth-password-l2|rsso|history0|history1)) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set md5-key [0-9]+) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set private-key ).*?-+END (ENCRYPTED|RSA|OPENSSH) PRIVATE KEY-+\n?"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set privatekey ).*?-+END (ENCRYPTED|RSA|OPENSSH) PRIVATE KEY-+\n?"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set ca )"-+BEGIN.*?-+END CERTIFICATE-+"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set csr ).*?-+END CERTIFICATE REQUEST-+"$/m, '\\1<configuration removed>'
    cfg
  end

  cmd "get system status" do |cfg|
    cfg = cfg.reject_lines [
      "Current Time",
      "System time",
      "Cluster uptime",
      "Uptime",
      "Disk Usage",
      "Release Version Information",
      "Branch Point",
      "Daylight Time Saving",
      "Time Zone",
      "x86-64 Applications",
      "File System",
      "Image Signature"
    ]
    comment cfg + "\n"
  end

  cmd "show" do |cfg|
    cfg.reject_lines ["#config-version="]
  end

  cmd :significant_changes do |cfg|
    cfg = cfg.reject_lines [
      /^ +set \S+ ENC \S+$/
    ]
    cfg.gsub(/set private-key .*?-+END \S+ PRIVATE KEY-+\n?"$/m, "")
  end

  cfg :telnet do
    username /^[lL]ogin:/
    password /^Password:/
  end

  cfg :ssh do
    exec true # run each command in an exec channel: no PTY, no pager, much faster
  end

  cfg :telnet, :ssh do
    pre_logout "exit"
  end
end



podman exec oxidized sh -c 'cd /home/oxidized/.config/oxidized && git --git-dir=devices.git log --format=%h -2 -- <node-name> | xargs -n2 sh -c "git --git-dir=devices.git diff \$1 \$0 -- <node-name>"' | grep -E "^[-+][^-+]" | grep -v " ENC "



models:
  fortios:
    vars:
      output_store_mode: on_significant

