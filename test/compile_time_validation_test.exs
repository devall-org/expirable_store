defmodule ExpirableStore.CompileTimeValidationTest do
  use ExUnit.Case, async: true

  describe "unknown name" do
    test "fetch/1 raises CompileError" do
      assert_raise CompileError, ~r/Unknown expirable :nonexistent/, fn ->
        Code.compile_string("require TestExpirables; TestExpirables.fetch(:nonexistent)")
      end
    end

    test "fetch/2 raises CompileError" do
      assert_raise CompileError, ~r/Unknown expirable :nonexistent/, fn ->
        Code.compile_string(~s[require TestExpirables; TestExpirables.fetch(:nonexistent, "k")])
      end
    end

    test "clear/1 raises CompileError" do
      assert_raise CompileError, ~r/Unknown expirable :nonexistent/, fn ->
        Code.compile_string("require TestExpirables; TestExpirables.clear(:nonexistent)")
      end
    end
  end

  describe "keyed/unkeyed arity mismatch" do
    test "fetch/1 on a keyed expirable raises CompileError" do
      assert_raise CompileError, ~r/is keyed; use fetch\/2/, fn ->
        Code.compile_string("require TestExpirables; TestExpirables.fetch(:cluster_lazy_keyed)")
      end
    end

    test "fetch/2 on a non-keyed expirable raises CompileError" do
      assert_raise CompileError, ~r/is not keyed; use fetch\/1/, fn ->
        Code.compile_string(~s[require TestExpirables; TestExpirables.fetch(:cluster_lazy, "k")])
      end
    end

    test "fetch!/1 on a keyed expirable raises CompileError" do
      assert_raise CompileError, ~r/is keyed; use fetch!\/2/, fn ->
        Code.compile_string("require TestExpirables; TestExpirables.fetch!(:cluster_lazy_keyed)")
      end
    end

    test "fetch!/2 on a non-keyed expirable raises CompileError" do
      assert_raise CompileError, ~r/is not keyed; use fetch!\/1/, fn ->
        Code.compile_string(~s[require TestExpirables; TestExpirables.fetch!(:cluster_lazy, "k")])
      end
    end
  end
end
