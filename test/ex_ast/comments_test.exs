defmodule ExAST.CommentsTest do
  use ExUnit.Case, async: true

  alias ExAST.Comments

  test "extracts comments with positions" do
    comments =
      Comments.extract("""
      # public API
      def run do
        value = 1 # inline
      end
      """)

    assert Enum.map(comments, & &1.text) == ["# public API", "# inline"]
    assert hd(comments).line == 1
  end

  test "joins comment text" do
    assert Comments.text("# one\n# two\n") == "# one\n# two"
  end

  test "finds comments associated with a range" do
    source = """
    # public API
    def run do
      value = 1 # inline
    end
    """

    [match] = ExAST.Patcher.find_all(source, "def run do ... end")

    assert [before] = Comments.associated(source, match.range, :before)
    assert before.text == "# public API"
    assert Enum.any?(Comments.associated(source, match.range, :inside), &(&1.text == "# inline"))
  end
end
