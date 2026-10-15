# Local override of the built-in Oxidized 'fortigate' model.
# Changes vs the stock model:
#   * SSH runs every command over an exec channel (no PTY, no pager) -> fast, large configs in seconds.
#   * Exec replies are wrapped in the device prompt; cmd :all strips it (stock cut_both is kept for Telnet).
#   * With VDOMs enabled there is no session state in exec mode, so global-context commands are sent
#     as one multi-line exec ("config global / <cmd> / end") instead of separate config global / end steps.
# Per-device opt-out back to the interactive shell: vars: { ssh_no_exec: true }
class FortiGate < Oxidized::Model
  using Refinements

  comment '# '

  prompt /^(\(\w\) )?([-\w.~]+(\s?[(\w\-.)]+)?~?\s?[#>$]\s?)$/

  # Matches a FortiOS prompt at the start of a line, e.g. "FW-01 # ", "FW-01 (global) # ", "FW-01 (root) $ "
  PROMPT_AT_LINE_START = /^(\(\w\) )?[-\w.~]+(\s?[(\w\-.)]+)?~?\s?[#>$] ?/

  # When a post-login-banner is enabled, you have to press "a" to log in
  expect /^\(Press\s'a'\sto\saccept\):/ do |data, re|
    send 'a'
    data.sub re, ''
  end

  expect /^--More--\s$/ do |data, re|
    send ' '
    data.sub re, ''
  end

  # true when a command needs "config global" and we cannot rely on session state (exec mode)
  def global_via_exec
    @vdom_enabled && !screenscrape
  end

  cmd :all do |cfg|
    # Remove junk after --More-- pager
    cfg = cfg.gsub(/\r +\r/, '')
    # Remove \r\n after command echo
    cfg = cfg.gsub("\r\n", "\n")
    if screenscrape
      # interactive shell: drop command echo (first line) and prompt (last line)
      cfg.cut_both
    else
      # exec channel: FortiOS prints its prompt before the first line, after the last line,
      # and once per command for multi-line execs. Strip them all, then trim blank edges.
      cfg = cfg.gsub(PROMPT_AT_LINE_START, '')
      cfg.sub(/\A\n+/, '').sub(/\n+\z/, "\n")
    end
  end

  cmd :secret do |cfg|
    # Remove private key for encrypted configs
    cfg.gsub! /^(\#private-encryption-key=).+/, '\\1 <configuration removed>'
    # ENC indicates an encrypted password, and secret indicates a secret string
    cfg.gsub! /(set .+ ENC) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set .*secret) .+/, '\\1 <configuration removed>'
    # A number of other statements also contains sensitive strings
    cfg.gsub! /(set (?:passwd|password|key|group-password|auth-password-l1|auth-password-l2|rsso|history0|history1)) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set md5-key [0-9]+) .+/, '\\1 <configuration removed>'
    cfg.gsub! /(set private-key ).*?-+END (ENCRYPTED|RSA|OPENSSH) PRIVATE KEY-+\n?"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set privatekey ).*?-+END (ENCRYPTED|RSA|OPENSSH) PRIVATE KEY-+\n?"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set ca )"-+BEGIN.*?-+END CERTIFICATE-+"$/m, '\\1<configuration removed>'
    cfg.gsub! /(set csr ).*?-+END CERTIFICATE REQUEST-+"$/m, '\\1<configuration removed>'
    cfg
  end

  cmd 'get system status' do |cfg|
    @vdom_enabled = cfg.match(/^Virtual domain configuration: (enable|multiple)/)
    @ha_cluster = cfg.match(/^Current HA mode: a-/) # a-p or a-a
    cfg = cfg.keep_lines [
      "Version: ",
      "Security Level: ",
      "Serial-Number: ",
      "BIOS version: ",
      "System Part-Number: ",
      "Hostname: ",
      "Operation Mode: ",
      "Current virtual domain: ",
      "Max number of virtual domains: ",
      "Virtual domains status:",
      "Virtual domain configuration: ",
      "FIPS-CC mode: ",
      "Current HA mode: ",
      "Private Encryption: ",
      # Lines in FortiGate-VM64
      "License Expiration Date: ",
      "License Status: ",
      "VM Resources: "
    ]
    comment cfg + "\n"
  end

  # Interactive shell only: enter the global context once; exec mode wraps each command instead.
  cmd 'config global', if: -> { @vdom_enabled && screenscrape } do |_cfg|
    ''
  end

  ha_status = lambda do |cfg|
    cfg = cfg.keep_lines [
      "HA Health Status:",
      "Model: ",
      "Mode: ",
      "number of member: ",
      /^(Master|Slave|Primary|Secondary): /
    ]
    comment cfg + "\n"
  end
  cmd 'get system ha status', if: -> { @ha_cluster && !global_via_exec }, &ha_status
  cmd "config global\nget system ha status\nend", if: -> { @ha_cluster && global_via_exec }, &ha_status

  hw_status = lambda { |cfg| comment cfg }
  cmd 'get hardware status', if: -> { !global_via_exec }, &hw_status
  cmd "config global\nget hardware status\nend", if: -> { global_via_exec }, &hw_status

  psu = lambda do |cfg|
    skip_patterns = [
      /Command fail\./,      # The device doesn't support this command
      /Power Supply +Status/ # We only get a status, but no serial numbers
    ]
    if skip_patterns.any? { |p| cfg.match?(p) }
      logger.debug "No PSU serial numbers available"
      ''
    else
      comment cfg
    end
  end
  cmd "diagnose hardware deviceinfo psu", if: -> { !global_via_exec }, &psu
  cmd "config global\ndiagnose hardware deviceinfo psu\nend", if: -> { global_via_exec }, &psu

  transceiver = lambda do |cfg|
    cfg = cfg.keep_lines [
      /^Interface \w/,
      "Vendor Name",
      "Part No.",
      "Serial No."
    ]
    cfg = cfg.reject_lines ["Transceiver is not detected"]
    comment cfg + "\n"
  end
  cmd "get system interface transceiver", if: -> { !global_via_exec }, &transceiver
  cmd "config global\nget system interface transceiver\nend", if: -> { global_via_exec }, &transceiver

  autoupdate = lambda do |cfg|
    if vars(:fortios_autoupdate)
      logger.warn("The variable fortios_autoupdate is deprecated. Migrate to fortigate_autoupdate")
    end
    cfg = cfg.sub(/FDS Address\n---------\n.*\n/, '')
    comment cfg.reject_lines ["Last Update", "Result :"]
  end
  cmd 'diagnose autoupdate version', if: -> { (vars(:fortios_autoupdate) || vars(:fortigate_autoupdate)) && !global_via_exec }, &autoupdate
  cmd "config global\ndiagnose autoupdate version\nend", if: -> { (vars(:fortios_autoupdate) || vars(:fortigate_autoupdate)) && global_via_exec }, &autoupdate

  cmd 'end', if: -> { @vdom_enabled && screenscrape } do |_cfg|
    ''
  end

  def clean_config(cfg)
    cfg = cfg.reject_lines ['#conf_file_ver=']
    cfg.gsub!(/(set comments "Error \(No order found for account ID \d+\) on).*/,
              '\\1 <stripped>')
    cfg
  end

  # If vars fullconfig is set to true, we get the full config (including default
  # values)
  cmd "show full-configuration | grep .", if: -> { vars(:fullconfig) } do |cfg|
    clean_config cfg
  end
  # else backup as in Fortigate GUI
  cmd "show | grep .", if: -> { !vars(:fullconfig) } do |cfg|
    clean_config cfg
  end

  cmd :significant_changes do |cfg|
    cfg = cfg.reject_lines [
      /^ +set \S+ ENC \S+$/
    ]
    cfg.gsub!(/(config firewall internet-service-name\n).*?(\nend\n)/m, '')
    cfg.gsub!(/set private-key .*?-+END \S+ PRIVATE KEY-+\n?"$/m, '')
    cfg
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
