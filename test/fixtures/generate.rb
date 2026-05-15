#!/usr/bin/env ruby
# Reproduces puts_table from importmap-rails commands.rb verbatim
# so we can generate byte-accurate fixtures.

def puts_table(array)
  column_sizes = array.reduce([]) do |lengths, row|
    row.each_with_index.map { |iterand, index| [lengths[index] || 0, iterand.to_s.length].max }
  end
  divider = "|" + column_sizes.map { |s| "-" * (s + 2) }.join("|") + "|"
  array.each_with_index do |row, row_number|
    row = row.fill(nil, row.size..(column_sizes.size - 1))
    row = row.each_with_index.map { |v, i| v.to_s + " " * (column_sizes[i] - v.to_s.length) }
    puts "| " + row.join(" | ") + " |"
    puts divider if row_number == 0
  end
end

# --- outdated_basic.txt
File.open("test/fixtures/outdated_basic.txt", "w") do |f|
  $stdout = f
  table = [["Package", "Current", "Latest"]]
  table << ["@hotwired/stimulus", "3.2.1", "3.2.2"]
  table << ["lodash", "4.17.20", "4.17.21"]
  table << ["react", "18.2.0", "19.0.0"]
  puts_table(table)
  puts " 3 outdated packages found"
ensure
  $stdout = STDOUT
end

# --- outdated_single.txt (singular "package")
File.open("test/fixtures/outdated_single.txt", "w") do |f|
  $stdout = f
  table = [["Package", "Current", "Latest"]]
  table << ["lodash", "4.17.20", "4.17.21"]
  puts_table(table)
  puts " 1 outdated package found"
ensure
  $stdout = STDOUT
end

# --- outdated_empty.txt
File.open("test/fixtures/outdated_empty.txt", "w") do |f|
  $stdout = f
  puts "No outdated packages found"
ensure
  $stdout = STDOUT
end

# --- outdated_with_error.txt — latest_version is nil and error string is shown instead
File.open("test/fixtures/outdated_with_error.txt", "w") do |f|
  $stdout = f
  table = [["Package", "Current", "Latest"]]
  table << ["lodash", "4.17.20", "4.17.21"]
  table << ["broken-pkg", "1.0.0", "Response code: 404"]
  puts_table(table)
  puts " 2 outdated packages found"
ensure
  $stdout = STDOUT
end

# --- audit_basic.txt
File.open("test/fixtures/audit_basic.txt", "w") do |f|
  $stdout = f
  table = [["Package", "Severity", "Vulnerable versions", "Vulnerability"]]
  table << ["lodash", "high", "<4.17.21", "Prototype Pollution in lodash"]
  table << ["@hotwired/stimulus", "moderate", "<3.2.2", "ReDoS in stimulus router"]
  puts_table(table)
  puts " 2 vulnerabilities found: 1 high, 1 moderate"
ensure
  $stdout = STDOUT
end

# --- audit_empty.txt
File.open("test/fixtures/audit_empty.txt", "w") do |f|
  $stdout = f
  puts "No vulnerable packages found"
ensure
  $stdout = STDOUT
end

# --- audit_critical.txt — single critical, singular pluralization
File.open("test/fixtures/audit_critical.txt", "w") do |f|
  $stdout = f
  table = [["Package", "Severity", "Vulnerable versions", "Vulnerability"]]
  table << ["evil-pkg", "critical", ">=0.0.0", "Remote code execution"]
  puts_table(table)
  puts " 1 vulnerability found: 1 critical"
ensure
  $stdout = STDOUT
end

puts "Generated fixtures in test/fixtures/"
