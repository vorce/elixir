# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

Code.require_file("test_helper.exs", __DIR__)

defmodule ModuleTest.ToBeUsed do
  def value, do: 1

  defmacro __using__(_) do
    target = __CALLER__.module
    Module.put_attribute(target, :has_callback, true)
    Module.put_attribute(target, :before_compile, __MODULE__)
    Module.put_attribute(target, :after_compile, __MODULE__)
    Module.put_attribute(target, :before_compile, {__MODULE__, :callback})
    quote(do: def(line, do: __ENV__.line))
  end

  defmacro __before_compile__(env) do
    quote(do: def(before_compile, do: unquote(Macro.Env.vars(env))))
  end

  defmacro __after_compile__(%Macro.Env{module: ModuleTest.ToUse} = env, bin)
           when is_binary(bin) do
    # Ensure module is not longer tracked as being loaded
    false = __MODULE__ in :elixir_module.compiler_modules()
    [] = Macro.Env.vars(env)
    :ok
  end

  defmacro callback(env) do
    value = Module.get_attribute(env.module, :has_callback)

    quote do
      def callback_value(true), do: unquote(value)
    end
  end
end

defmodule ModuleTest.ToUse do
  # Moving the next line around can make tests fail
  42 = __ENV__.line
  var = 1
  # Not available in callbacks
  _ = var
  def callback_value(false), do: false
  use ModuleTest.ToBeUsed
end

defmodule ModuleTest do
  use ExUnit.Case, async: true

  doctest Module

  Module.register_attribute(__MODULE__, :register_unset_example, persist: true)
  Module.register_attribute(__MODULE__, :register_empty_example, accumulate: true, persist: true)
  Module.register_attribute(__MODULE__, :register_example, accumulate: true, persist: true)
  @register_example :it_works
  @register_example :still_works

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
  end

  defmacrop in_module(block) do
    quote do
      defmodule(Temp, unquote(block))
      purge(Temp)
    end
  end

  test "module attributes returns value" do
    in_module do
      assert @return([:foo, :bar]) == :ok
      _ = @return
    end
  end

  test "raises on write access attempts from __after_compile__/2" do
    contents =
      quote do
        @after_compile __MODULE__

        def __after_compile__(%Macro.Env{module: module}, bin) when is_binary(bin) do
          Module.put_attribute(module, :foo, 42)
        end
      end

    assert_raise ArgumentError,
                 "could not call Module.put_attribute/3 because the module ModuleTest.Raise is in read-only mode (@after_compile)",
                 fn ->
                   Module.create(ModuleTest.Raise, contents, __ENV__)
                 end
  end

  test "supports read access to module from __after_compile__/2" do
    defmodule ModuleTest.NoRaise do
      @after_compile __MODULE__
      @foo 42

      def __after_compile__(%Macro.Env{module: module}, bin) when is_binary(bin) do
        send(self(), Module.get_attribute(module, :foo))
      end
    end

    assert_received 42
  end

  test "supports @after_verify for inlined modules" do
    defmodule ModuleTest.AfterVerify do
      @after_verify __MODULE__

      def __after_verify__(ModuleTest.AfterVerify) do
        send(self(), ModuleTest.AfterVerify)
      end
    end

    assert_received ModuleTest.AfterVerify
  end

  test "in memory modules are tagged as so" do
    assert :code.which(__MODULE__) == ~c""
  end

  ## Callbacks

  test "retrieves line from use callsite" do
    assert ModuleTest.ToUse.line() == 47
  end

  test "executes custom before_compile callback" do
    assert ModuleTest.ToUse.callback_value(true) == true
    assert ModuleTest.ToUse.callback_value(false) == false
  end

  test "executes default before_compile callback" do
    assert ModuleTest.ToUse.before_compile() == []
  end

  def __on_definition__(env, kind, name, args, guards, expr) do
    Process.put(env.module, {args, guards, expr})
    assert env.module == ModuleTest.OnDefinition
    assert kind == :def
    assert name == :hello
    assert Module.defines?(env.module, {:hello, 2})
  end

  test "executes on definition callback" do
    defmodule OnDefinition do
      @on_definition ModuleTest

      def hello(foo, bar)

      assert {[{:foo, _, _}, {:bar, _, _}], [], nil} = Process.get(ModuleTest.OnDefinition)

      def hello(foo, bar) do
        foo + bar
      end

      assert {[{:foo, _, _}, {:bar, _, _}], [], [do: {:+, _, [{:foo, _, nil}, {:bar, _, nil}]}]} =
               Process.get(ModuleTest.OnDefinition)
    end
  end

  defmacro __before_compile__(_) do
    quote do
      def constant, do: 1
      defoverridable constant: 0
    end
  end

  test "may set overridable inside before_compile callback" do
    defmodule OverridableWithBeforeCompile do
      @before_compile ModuleTest
    end

    assert OverridableWithBeforeCompile.constant() == 1
  end

  describe "__info__(:attributes)" do
    test "reserved attributes" do
      assert List.keyfind(ExUnit.Server.__info__(:attributes), :behaviour, 0) ==
               {:behaviour, [GenServer]}
    end

    test "registered attributes" do
      assert Enum.filter(__MODULE__.__info__(:attributes), &match?({:register_example, _}, &1)) ==
               [{:register_example, [:it_works]}, {:register_example, [:still_works]}]
    end

    test "registered attributes with no values are not present" do
      refute List.keyfind(__MODULE__.__info__(:attributes), :register_unset_example, 0)
      refute List.keyfind(__MODULE__.__info__(:attributes), :register_empty_example, 0)
    end
  end

  @some_attribute [1]
  @other_attribute [3, 2, 1]

  test "inside function attributes" do
    assert @some_attribute == [1]
    assert @other_attribute == [3, 2, 1]
  end

  ## Naming

  test "concat" do
    assert Module.concat(Foo, Bar) == Foo.Bar
    assert Module.concat(Foo, :Bar) == Foo.Bar
    assert Module.concat(Foo, "Bar") == Foo.Bar
    assert Module.concat(Foo, Bar.Baz) == Foo.Bar.Baz
    assert Module.concat(Foo, "Bar.Baz") == Foo.Bar.Baz
    assert Module.concat(Bar, nil) == Elixir.Bar
  end

  test "safe concat" do
    assert Module.safe_concat(Foo, :Bar) == Foo.Bar

    assert_raise ArgumentError, fn ->
      Module.safe_concat(SafeConcat, Doesnt.Exist)
    end
  end

  test "split" do
    module = Very.Long.Module.Name.And.Even.Longer
    assert Module.split(module) == ["Very", "Long", "Module", "Name", "And", "Even", "Longer"]
    assert Module.split("Elixir.Very.Long") == ["Very", "Long"]

    assert_raise ArgumentError, "expected an Elixir module, got: :just_an_atom", fn ->
      Module.split(:just_an_atom)
    end

    assert_raise ArgumentError, "expected an Elixir module, got: \"Foo\"", fn ->
      Module.split("Foo")
    end

    assert Module.concat(Module.split(module)) == module
  end

  test "__MODULE__" do
    assert Code.eval_string("__MODULE__.Foo") |> elem(0) == Foo
  end

  test "__ENV__.file" do
    assert Path.basename(__ENV__.file) == "module_test.exs"
  end

  @file "sample.ex"
  test "@file sets __ENV__.file" do
    assert __ENV__.file == Path.absname("sample.ex")
  end

  test "@file raises when invalid" do
    assert_raise ArgumentError, ~r"@file is a built-in module attribute", fn ->
      defmodule BadFile do
        @file :oops
        def my_fun, do: :ok
      end
    end
  end

  ## Creation

  test "defmodule" do
    result =
      defmodule Defmodule do
        1 + 2
      end

    assert {:module, Defmodule, binary, 3} = result
    assert is_binary(binary)
  end

  test "defmodule with atom" do
    result =
      defmodule :root_defmodule do
        :ok
      end

    assert {:module, :root_defmodule, _, _} = result
  end

  test "does not leak alias from atom" do
    defmodule :"Elixir.ModuleTest.RawModule" do
      def hello, do: :world
    end

    refute __ENV__.aliases[Elixir.ModuleTest]
    refute __ENV__.aliases[Elixir.RawModule]
    assert ModuleTest.RawModule.hello() == :world
  end

  test "does not leak alias from non-atom alias" do
    defmodule __MODULE__.NonAtomAlias do
      def hello, do: :world
    end

    refute __ENV__.aliases[Elixir.ModuleTest]
    refute __ENV__.aliases[Elixir.NonAtomAlias]
    assert Elixir.ModuleTest.NonAtomAlias.hello() == :world
  end

  test "does not leak alias from Elixir root alias" do
    defmodule Elixir.ModuleTest.ElixirRootAlias do
      def hello, do: :world
    end

    refute __ENV__.aliases[Elixir.ModuleTest]
    refute __ENV__.aliases[Elixir.ElixirRootAlias]
    assert Elixir.ModuleTest.ElixirRootAlias.hello() == :world
  end

  test "does not warn on captured underscored vars" do
    _unused = 123

    defmodule __MODULE__.NoVarWarning do
    end
  end

  @compile {:no_warn_undefined, ModuleCreateSample}

  test "create" do
    contents =
      quote do
        def world, do: true
      end

    {:module, ModuleCreateSample, _, _} = Module.create(ModuleCreateSample, contents, __ENV__)
    assert ModuleCreateSample.world()
  end

  test "create with a reserved module name" do
    contents =
      quote do
        def world, do: true
      end

    assert_raise CompileError, ~r/cannot compile module Elixir/, fn ->
      Code.with_diagnostics(fn ->
        Module.create(Elixir, contents, __ENV__)
      end)
    end
  end

  @compile {:no_warn_undefined, ModuleTracersSample}

  test "create with propagated tracers" do
    contents =
      quote do
        def world, do: true
      end

    env = %{__ENV__ | tracers: [:invalid]}
    {:module, ModuleTracersSample, _, _} = Module.create(ModuleTracersSample, contents, env)
    assert ModuleTracersSample.world()
  end

  @compile {:no_warn_undefined, ModuleHygiene}

  test "create with aliases/var hygiene" do
    contents =
      quote do
        alias List, as: L

        def test do
          L.flatten([1, [2], 3])
        end
      end

    Module.create(ModuleHygiene, contents, __ENV__)
    assert ModuleHygiene.test() == [1, 2, 3]
  end

  test "ensure function clauses are sorted (to avoid non-determinism in module vsn)" do
    {_, _, binary, _} =
      defmodule Ordered do
        def foo(:foo), do: :bar
        def baz(:baz), do: :bat
      end

    {:ok, {ModuleTest.Ordered, [abstract_code: {:raw_abstract_v1, abstract_code}]}} =
      :beam_lib.chunks(binary, [:abstract_code])

    # We need to traverse functions instead of using :exports as exports are sorted
    funs = for {:function, _, name, arity, _} <- abstract_code, do: {name, arity}
    assert funs == [__info__: 1, baz: 1, foo: 1]
  end

  @compile {:no_warn_undefined, ModuleCreateGenerated}

  test "create with generated true does not emit warnings" do
    contents =
      quote generated: true do
        def world, do: true
        def world, do: false
      end

    {:module, ModuleCreateGenerated, _, _} =
      Module.create(ModuleCreateGenerated, contents, __ENV__)

    assert ModuleCreateGenerated.world()
  end

  test "uses the debug_info chunk" do
    {:module, ModuleCreateDebugInfo, binary, _} =
      Module.create(ModuleCreateDebugInfo, :ok, __ENV__)

    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(binary, [:debug_info])

    {:ok, map} = backend.debug_info(:elixir_v1, ModuleCreateDebugInfo, data, [])
    assert map.module == ModuleCreateDebugInfo
  end

  test "uses the debug_info chunk when explicitly set to true" do
    {:module, ModuleCreateDebugInfoTrue, binary, _} =
      Module.create(ModuleCreateDebugInfoTrue, quote(do: @compile({:debug_info, true})), __ENV__)

    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(binary, [:debug_info])

    {:ok, map} = backend.debug_info(:elixir_v1, ModuleCreateDebugInfoTrue, data, [])
    assert map.module == ModuleCreateDebugInfoTrue
  end

  test "uses the debug_info chunk even if debug_info is set to false" do
    {:module, ModuleCreateNoDebugInfo, binary, _} =
      Module.create(ModuleCreateNoDebugInfo, quote(do: @compile({:debug_info, false})), __ENV__)

    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(binary, [:debug_info])

    assert backend.debug_info(:elixir_v1, ModuleCreateNoDebugInfo, data, []) == {:error, :missing}
  end

  test "compiles to core" do
    import PathHelpers

    write_beam(
      defmodule ExampleModule do
      end
    )

    {:ok, {ExampleModule, [{~c"Dbgi", dbgi}]}} =
      ExampleModule |> :code.which() |> :beam_lib.chunks([~c"Dbgi"])

    {:debug_info_v1, backend, data} = :erlang.binary_to_term(dbgi)
    {:ok, core} = backend.debug_info(:core_v1, ExampleModule, data, [])
    assert is_tuple(core)
  end

  test "no function in module body" do
    in_module do
      assert __ENV__.function == nil
    end
  end

  test "does not use ETS tables named after the module" do
    in_module do
      assert :ets.info(__MODULE__) == :undefined
    end
  end

  ## Definitions

  test "defines?" do
    in_module do
      refute Module.defines?(__MODULE__, {:foo, 0})
      def foo(), do: bar()
      assert Module.defines?(__MODULE__, {:foo, 0})
      assert Module.defines?(__MODULE__, {:foo, 0}, :def)

      refute Module.defines?(__MODULE__, {:bar, 0}, :defp)
      defp bar(), do: :ok
      assert Module.defines?(__MODULE__, {:bar, 0}, :defp)

      refute Module.defines?(__MODULE__, {:baz, 0}, :defmacro)
      defmacro baz(), do: :ok
      assert Module.defines?(__MODULE__, {:baz, 0}, :defmacro)
    end
  end

  test "definitions in" do
    in_module do
      defp bar(), do: :ok
      def foo(1, 2, 3), do: bar()

      defmacrop macro_bar(), do: 4
      defmacro macro_foo(1, 2, 3), do: macro_bar()

      assert Module.definitions_in(__MODULE__) |> Enum.sort() ==
               [{:bar, 0}, {:foo, 3}, {:macro_bar, 0}, {:macro_foo, 3}]

      assert Module.definitions_in(__MODULE__, :def) == [foo: 3]
      assert Module.definitions_in(__MODULE__, :defp) == [bar: 0]
      assert Module.definitions_in(__MODULE__, :defmacro) == [macro_foo: 3]
      assert Module.definitions_in(__MODULE__, :defmacrop) == [macro_bar: 0]

      defoverridable foo: 3

      assert Module.definitions_in(__MODULE__) |> Enum.sort() ==
               [{:bar, 0}, {:macro_bar, 0}, {:macro_foo, 3}]

      assert Module.definitions_in(__MODULE__, :def) == []
    end
  end

  test "get_definition/2 and delete_definition/2" do
    in_module do
      def foo(a, b), do: a + b

      assert {:v1, :def, def_meta,
              [
                {clause_meta, [{:a, _, nil}, {:b, _, nil}], [],
                 {{:., _, [:erlang, :+]}, _, [{:a, _, nil}, {:b, _, nil}]}}
              ]} = Module.get_definition(__MODULE__, {:foo, 2})

      assert [line: _, column: _] = Keyword.take(def_meta, [:line, :column])
      assert [line: _, column: _] = Keyword.take(clause_meta, [:line, :column])
      assert {:v1, :def, _, []} = Module.get_definition(__MODULE__, {:foo, 2}, skip_clauses: true)

      assert Module.delete_definition(__MODULE__, {:foo, 2})
      assert Module.get_definition(__MODULE__, {:foo, 2}) == nil
      refute Module.delete_definition(__MODULE__, {:foo, 2})
    end
  end

  test "make_overridable/2 with invalid arguments" do
    contents =
      quote do
        Module.make_overridable(__MODULE__, [{:foo, 256}])
      end

    message =
      "each element in tuple list has to be a {function_name :: atom, arity :: 0..255} " <>
        "tuple, got: {:foo, 256}"

    assert_raise ArgumentError, message, fn ->
      Module.create(MakeOverridable, contents, __ENV__)
    end
  after
    purge(MakeOverridable)
  end

  test "raise when called with already compiled module" do
    message =
      "could not call Module.get_attribute/2 because the module Enum is already compiled. " <>
        "Use the Module.__info__/1 callback or Code.fetch_docs/1 instead"

    assert_raise ArgumentError, message, fn ->
      Module.get_attribute(Enum, :moduledoc)
    end
  end

  describe "get_attribute/3" do
    test "returns a list when the attribute is marked as `accumulate: true`" do
      in_module do
        Module.register_attribute(__MODULE__, :value, accumulate: true)
        assert Module.get_attribute(__MODULE__, :value) == []
        Module.put_attribute(__MODULE__, :value, 1)
        assert Module.get_attribute(__MODULE__, :value) == [1]
        Module.put_attribute(__MODULE__, :value, 2)
        assert Module.get_attribute(__MODULE__, :value) == [2, 1]
      end
    end

    test "returns the value of the attribute if it exists" do
      in_module do
        Module.put_attribute(__MODULE__, :attribute, 1)
        assert Module.get_attribute(__MODULE__, :attribute) == 1
        assert Module.get_attribute(__MODULE__, :attribute, :default) == 1
        Module.put_attribute(__MODULE__, :attribute, nil)
        assert Module.get_attribute(__MODULE__, :attribute, :default) == nil
      end
    end

    test "returns the value of the attribute if persisted" do
      in_module do
        Module.register_attribute(__MODULE__, :value, persist: true)
        assert Module.get_attribute(__MODULE__, :value, 123) == 123
        Module.put_attribute(__MODULE__, :value, 1)
        assert Module.get_attribute(__MODULE__, :value) == 1
        Module.put_attribute(__MODULE__, :value, 2)
        assert Module.get_attribute(__MODULE__, :value) == 2
        Module.delete_attribute(__MODULE__, :value)
        assert Module.get_attribute(__MODULE__, :value, 123) == 123
      end
    end

    test "returns the passed default if the attribute does not exist" do
      in_module do
        assert Module.get_attribute(__MODULE__, :attribute, :default) == :default
      end
    end
  end

  describe "get_last_attribute/3" do
    test "returns the last set value when the attribute is marked as `accumulate: true`" do
      in_module do
        Module.register_attribute(__MODULE__, :value, accumulate: true)
        Module.put_attribute(__MODULE__, :value, 1)
        assert Module.get_last_attribute(__MODULE__, :value) == 1
        Module.put_attribute(__MODULE__, :value, 2)
        assert Module.get_last_attribute(__MODULE__, :value) == 2
      end
    end

    test "returns the value of the non-accumulate attribute if it exists" do
      in_module do
        Module.put_attribute(__MODULE__, :attribute, 1)
        assert Module.get_last_attribute(__MODULE__, :attribute) == 1
        Module.put_attribute(__MODULE__, :attribute, nil)
        assert Module.get_last_attribute(__MODULE__, :attribute, :default) == nil
      end
    end

    test "returns the passed default if the accumulate attribute has not yet been set" do
      in_module do
        Module.register_attribute(__MODULE__, :value, accumulate: true)
        assert Module.get_last_attribute(__MODULE__, :value) == nil
        assert Module.get_last_attribute(__MODULE__, :value, :default) == :default
      end
    end

    test "returns the passed default if the non-accumulate attribute does not exist" do
      in_module do
        assert Module.get_last_attribute(__MODULE__, :value, :default) == :default
      end
    end
  end

  describe "has_attribute?/2 and attributes_in/2" do
    test "returns true when attribute has been defined" do
      in_module do
        @foo 1
        Module.register_attribute(__MODULE__, :bar, [])
        Module.register_attribute(__MODULE__, :baz, accumulate: true)
        Module.put_attribute(__MODULE__, :qux, 2)

        # silence warning
        _ = @foo

        assert Module.has_attribute?(__MODULE__, :foo)
        assert :foo in Module.attributes_in(__MODULE__)
        assert Module.has_attribute?(__MODULE__, :bar)
        assert :bar in Module.attributes_in(__MODULE__)
        assert Module.has_attribute?(__MODULE__, :baz)
        assert :baz in Module.attributes_in(__MODULE__)
        assert Module.has_attribute?(__MODULE__, :qux)
        assert :qux in Module.attributes_in(__MODULE__)
      end
    end

    test "returns false when attribute has not been defined" do
      in_module do
        refute Module.has_attribute?(__MODULE__, :foo)
      end
    end

    test "returns false when attribute has been deleted" do
      in_module do
        @foo 1
        Module.delete_attribute(__MODULE__, :foo)

        refute Module.has_attribute?(__MODULE__, :foo)
      end
    end
  end

  test "@on_load" do
    Process.register(self(), :on_load_test_process)

    defmodule OnLoadTest do
      @on_load :on_load

      defp on_load do
        send(:on_load_test_process, :on_loaded)
        :ok
      end
    end

    assert_received :on_loaded
  end
end
