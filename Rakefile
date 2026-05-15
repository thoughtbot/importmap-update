require "minitest/test_task"

Minitest::TestTask.create

begin
  require "standard/rake"
  task default: %i[test standard]
rescue LoadError
  task default: :test
end
