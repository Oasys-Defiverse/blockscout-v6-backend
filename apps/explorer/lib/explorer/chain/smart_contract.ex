defmodule Explorer.Chain.SmartContract.Schema do
  @moduledoc """
    Models smart-contract.
  """
  alias Explorer.Chain.SmartContract.ExternalLibrary

  alias Explorer.Chain.{
    Address,
    DecompiledSmartContract,
    Hash,
    SmartContractAdditionalSource
  }

  case Application.compile_env(:explorer, :chain_type) do
    :zksync ->
      @chain_type_fields quote(
                           do: [
                             field(:optimization_runs, :string),
                             field(:zk_compiler_version, :string, null: true)
                           ]
                         )

    _ ->
      @chain_type_fields quote(do: [field(:optimization_runs, :integer)])
  end

  defmacro generate do
    quote do
      typed_schema "smart_contracts" do
        field(:name, :string, null: false)
        field(:compiler_version, :string, null: false)
        field(:optimization, :boolean, null: false)
        field(:contract_source_code, :string, null: false)
        field(:constructor_arguments, :string)
        field(:evm_version, :string)
        embeds_many(:external_libraries, ExternalLibrary, on_replace: :delete)
        field(:abi, {:array, :map})
        field(:verified_via_sourcify, :boolean)
        field(:verified_via_eth_bytecode_db, :boolean)
        field(:verified_via_verifier_alliance, :boolean)
        field(:partially_verified, :boolean)
        field(:file_path, :string)
        field(:is_vyper_contract, :boolean)
        field(:is_changed_bytecode, :boolean, default: false)
        field(:bytecode_checked_at, :utc_datetime_usec, default: DateTime.add(DateTime.utc_now(), -86400, :second))
        field(:contract_code_md5, :string, null: false)
        field(:compiler_settings, :map)
        field(:autodetect_constructor_args, :boolean, virtual: true)
        field(:is_yul, :boolean, virtual: true)
        field(:metadata_from_verified_bytecode_twin, :boolean, virtual: true)
        field(:license_type, Ecto.Enum, values: @license_enum, default: :none)
        field(:certified, :boolean)
        field(:is_blueprint, :boolean)

        has_many(
          :decompiled_smart_contracts,
          DecompiledSmartContract,
          foreign_key: :address_hash
        )

        belongs_to(
          :address,
          Address,
          foreign_key: :address_hash,
          references: :hash,
          type: Hash.Address,
          null: false
        )

        has_many(:smart_contract_additional_sources, SmartContractAdditionalSource,
          references: :address_hash,
          foreign_key: :address_hash
        )

        timestamps()

        unquote_splicing(@chain_type_fields)
      end
    end
  end
end

defmodule Explorer.Chain.SmartContract do
  @moduledoc """
  The representation of a verified Smart Contract.

  "A contract in the sense of Solidity is a collection of code (its functions)
  and data (its state) that resides at a specific address on the Ethereum
  blockchain."
  http://solidity.readthedocs.io/en/v0.4.24/introduction-to-smart-contracts.html
  """

  require Logger
  require Explorer.Chain.SmartContract.Schema

  use Explorer.Schema

  alias ABI.FunctionSelector
  alias Ecto.{Changeset, Multi}
  alias Explorer.{Chain, Repo, SortingHelper}

  alias Explorer.Chain.{
    Address,
    ContractMethod,
    Data,
    Hash,
    InternalTransaction,
    SmartContract,
    SmartContractAdditionalSource,
    Transaction
  }

  alias Explorer.Chain.Address.Name, as: AddressName

  alias Explorer.Chain.SmartContract.Proxy
  alias Explorer.Chain.SmartContract.Proxy.Models.Implementation
  alias Explorer.Helper, as: ExplorerHelper
  alias Explorer.SmartContract.Helper
  alias Explorer.SmartContract.Solidity.Verifier

  @typep api? :: {:api?, true | false}

  @burn_address_hash_string "0x0000000000000000000000000000000000000000"
  @dead_address_hash_string "0x000000000000000000000000000000000000dEaD"

  @required_attrs ~w(compiler_version optimization address_hash contract_code_md5)a

  @optional_common_attrs ~w(name contract_source_code evm_version optimization_runs constructor_arguments verified_via_sourcify verified_via_eth_bytecode_db verified_via_verifier_alliance partially_verified file_path is_vyper_contract is_changed_bytecode bytecode_checked_at autodetect_constructor_args license_type certified is_blueprint)a

  @optional_changeset_attrs ~w(abi compiler_settings)a
  @optional_invalid_contract_changeset_attrs ~w(autodetect_constructor_args)a

  @chain_type_optional_attrs (case Application.compile_env(:explorer, :chain_type) do
                                :zksync ->
                                  ~w(zk_compiler_version)a

                                _ ->
                                  ~w()a
                              end)

  @create_zksync_abi [
    %{
      "inputs" => [
        %{"internalType" => "bytes32", "name" => "_salt", "type" => "bytes32"},
        %{"internalType" => "bytes32", "name" => "_bytecodeHash", "type" => "bytes32"},
        %{"internalType" => "bytes", "name" => "_input", "type" => "bytes"}
      ],
      "name" => "create2",
      "outputs" => [%{"internalType" => "address", "name" => "", "type" => "address"}],
      "stateMutability" => "payable",
      "type" => "function"
    },
    %{
      "inputs" => [
        %{"internalType" => "bytes32", "name" => "_salt", "type" => "bytes32"},
        %{"internalType" => "bytes32", "name" => "_bytecodeHash", "type" => "bytes32"},
        %{"internalType" => "bytes", "name" => "_input", "type" => "bytes"}
      ],
      "name" => "create",
      "outputs" => [%{"internalType" => "address", "name" => "", "type" => "address"}],
      "stateMutability" => "payable",
      "type" => "function"
    }
  ]

  @doc """
    Returns burn address hash
  """
  @spec burn_address_hash_string() :: EthereumJSONRPC.address()
  def burn_address_hash_string do
    @burn_address_hash_string
  end

  @doc """
    Returns dead address hash
  """
  @spec dead_address_hash_string() :: EthereumJSONRPC.address()
  def dead_address_hash_string do
    @dead_address_hash_string
  end

  @default_sorting [desc: :id]

  @typedoc """
  The name of a parameter to a function or event.
  """
  @type parameter_name :: String.t()

  @typedoc """
  Canonical Input or output [type](https://solidity.readthedocs.io/en/develop/abi-spec.html#types).

  * `"address"` - equivalent to `uint160`, except for the assumed interpretation and language typing. For computing the
    function selector, `address` is used.
  * `"bool"` - equivalent to uint8 restricted to the values 0 and 1. For computing the function selector, bool is used.
  * `bytes`: dynamic sized byte sequence
  * `"bytes<M>"` - binary type of `M` bytes, `0 < M <= 32`.
  * `"fixed"` - synonym for `"fixed128x18".  For computing the function selection, `"fixed128x8"` has to be used.
  * `"fixed<M>x<N>"` - signed fixed-point decimal number of `M` bits, `8 <= M <= 256`, `M % 8 ==0`, and `0 < N <= 80`,
    which denotes the value `v` as `v / (10 ** N)`.
  * `"function" - an address (`20` bytes) followed by a function selector (`4` bytes). Encoded identical to `bytes24`.
  * `"int"` - synonym for `"int256"`. For computing the function selector `"int256"` has to be used.
  * `"int<M>"` - two’s complement signed integer type of `M` bits, `0 < M <= 256`, `M % 8 == 0`.
  * `"string"` - dynamic sized unicode string assumed to be UTF-8 encoded.
  * `"tuple"` - a tuple.
  * `"(<T1>,<T2>,...,<Tn>)"` - tuple consisting of the `t:type/0`s `<T1>`, …, `Tn`, `n >= 0`.
  * `"<type>[]"` - a variable-length array of elements of the given `type`.
  * `"<type>[M]"` - a fixed-length array of `M` elements, `M >= 0`, of the given `t:type/0`.
  * `"ufixed"` - synonym for `"ufixed128x18".  For computing the function selection, `"ufixed128x8"` has to be used.
  * `"ufixed<M>x<N>"` - unsigned variant of `"fixed<M>x<N>"`
  * `"uint"` - synonym for `"uint256"`. For computing the function selector `"uint256"` has to be used.
  * `"uint<M>"` - unsigned integer type of `M` bits, `0 < M <= 256`, `M % 8 == 0.` e.g. `uint32`, `uint8`, `uint256`.
  """
  @type type :: String.t()

  @typedoc """
  Name of component.
  """
  @type component_name :: String.t()

  @typedoc """
  A component of a [tuple](https://solidity.readthedocs.io/en/develop/abi-spec.html#handling-tuple-types).

  * `"name"` - name of the component.
  * `"type"` - `t:type/0`.
  """
  @type component :: %{String.t() => component_name() | type()}

  @typedoc """
  The components of a [tuple](https://solidity.readthedocs.io/en/develop/abi-spec.html#handling-tuple-types).
  """
  @type components :: [component()]

  @typedoc """
  * `"event"`
  """
  @type event_type :: String.t()

  @typedoc """
  Name of an event in an `t:abi/0`.
  """
  @type event_name :: String.t()

  @typedoc """
  * `true` - if field is part of the `t:Explorer.Chain.Log.t/0` `topics`.
  * `false` - if field is part of the `t:Explorer.Chain.Log.t/0` `data`.
  """
  @type indexed :: boolean()

  @typedoc """
  * `"name"` - `t:parameter_name/0`.
  * `"type"` - `t:type/0`.
  * `"components" `- `t:components/0` used when `"type"` is a tuple type.
  * `"indexed"` - `t:indexed/0`.
  """
  @type event_input :: %{String.t() => parameter_name() | type() | components() | indexed()}

  @typedoc """
  * `true` - event was declared as `anonymous`.
  * `false` - otherwise.
  """
  @type anonymous :: boolean()

  @typedoc """
  * `"type" - `t:event_type/0`
  * `"name"` - `t:event_name/0`
  * `"inputs"` - `t:list/0` of `t:event_input/0`.
  * `"anonymous"` - t:anonymous/0`
  """
  @type event_description :: %{String.t() => term()}

  @typedoc """
  * `"function"`
  * `"constructor"`
  * `"fallback"` - the default, unnamed function
  """
  @type function_type :: String.t()

  @typedoc """
  Name of a function in an `t:abi/0`.
  """
  @type function_name :: String.t()

  @typedoc """
  * `"name"` - t:parameter_name/0`.
  * `"type"` - `t:type/0`.
  * `"components"` - `t:components/0` used when `"type"` is a tuple type.
  """
  @type function_input :: %{String.t() => parameter_name() | type() | components()}

  @typedoc """
  * `"type" - `t:type/0`
  """
  @type function_output :: %{String.t() => type()}

  @typedoc """
  * `"pure"` - [specified to not read blockchain state](https://solidity.readthedocs.io/en/develop/contracts.html#pure-functions).
  * `"view"` - [specified to not modify the blockchain state](https://solidity.readthedocs.io/en/develop/contracts.html#view-functions).
  * `"nonpayable"` - function does not accept Ether.
    **NOTE**: Sending non-zero Ether to non-payable function will revert the transaction.
  * `"payable"` - function accepts Ether.
  """
  @type state_mutability :: String.t()

  @typedoc """
  **Deprecated:** Use `t:function_description/0` `"stateMutability"`:

  * `true` - `"payable"`
  * `false` - `"pure"`, `"view"`, or `"nonpayable"`.
  """
  @type payable :: boolean()

  @typedoc """
  **Deprecated:** Use `t:function_description/0` `"stateMutability"`:

  * `true` - `"pure"` or `"view"`.
  * `false` - `"nonpayable"` or `"payable"`.
  """
  @type constant :: boolean()

  @typedoc """
  The [function description](https://solidity.readthedocs.io/en/develop/abi-spec.html#json) for a function in the
  `t:abi.t/0`.

  * `"type"` - `t:function_type/0`
  * `"name" - `t:function_name/0`
  * `"inputs` - `t:list/0` of `t:function_input/0`.
  * `"outputs" - `t:list/0` of `t:output/0`.
  * `"stateMutability"` - `t:state_mutability/0`
  * `"payable"` - `t:payable/0`.
    **WARNING:** Deprecated and will be removed in the future.  Use `"stateMutability"` instead.
  * `"constant"` - `t:constant/0`.
    **WARNING:** Deprecated and will be removed in the future.  Use `"stateMutability"` instead.
  """
  @type function_description :: %{
          String.t() =>
            function_type()
            | function_name()
            | [function_input()]
            | [function_output()]
            | state_mutability()
            | payable()
            | constant()
        }

  @typedoc """
  The [JSON ABI specification](https://solidity.readthedocs.io/en/develop/abi-spec.html#json) for a contract.
  """
  @type abi :: [event_description | function_description]

  @doc """
    1. No License (None)
    2. The Unlicense (Unlicense)
    3. MIT License (MIT)
    4. GNU General Public License v2.0 (GNU GPLv2)
    5. GNU General Public License v3.0 (GNU GPLv3)
    6. GNU Lesser General Public License v2.1 (GNU LGPLv2.1)
    7. GNU Lesser General Public License v3.0 (GNU LGPLv3)
    8. BSD 2-clause "Simplified" license (BSD-2-Clause)
    9. BSD 3-clause "New" Or "Revised" license* (BSD-3-Clause)
    10. Mozilla Public License 2.0 (MPL-2.0)
    11. Open Software License 3.0 (OSL-3.0)
    12. Apache 2.0 (Apache-2.0)
    13. GNU Affero General Public License (GNU AGPLv3)
    14. Business Source License (BSL 1.1)
  """
  @license_enum [
    none: 1,
    unlicense: 2,
    mit: 3,
    gnu_gpl_v2: 4,
    gnu_gpl_v3: 5,
    gnu_lgpl_v2_1: 6,
    gnu_lgpl_v3: 7,
    bsd_2_clause: 8,
    bsd_3_clause: 9,
    mpl_2_0: 10,
    osl_3_0: 11,
    apache_2_0: 12,
    gnu_agpl_v3: 13,
    bsl_1_1: 14
  ]

  @typedoc """
  * `name` - the human-readable name of the smart contract.
  * `compiler_version` - the version of the Solidity compiler used to compile `contract_source_code` with `optimization`
    into `address` `t:Explorer.Chain.Address.t/0` `contract_code`.
    #{case Application.compile_env(:explorer, :chain_type) do
    :zksync -> """
       * `zk_compiler_version` - the version of ZkSolc or ZkVyper compilers.
      """
    _ -> ""
  end}
  * `optimization` - whether optimizations were turned on when compiling `contract_source_code` into `address`
    `t:Explorer.Chain.Address.t/0` `contract_code`.
  * `contract_source_code` - the Solidity source code that was compiled by `compiler_version` with `optimization` to
    produce `address` `t:Explorer.Chain.Address.t/0` `contract_code`.
  * `abi` - The [JSON ABI specification](https://solidity.readthedocs.io/en/develop/abi-spec.html#json) for this
    contract.
  * `verified_via_sourcify` - whether contract verified through Sourcify utility or not.
  * `verified_via_eth_bytecode_db` - whether contract automatically verified via eth-bytecode-db or not.
  * `verified_via_verifier_alliance` - whether contract automatically verified via Verifier Alliance or not.
  * `partially_verified` - whether contract verified using partial matched source code or not.
  * `is_vyper_contract` - boolean flag, determines if contract is Vyper or not
  * `file_path` - show the filename or path to the file of the contract source file
  * `is_changed_bytecode` - boolean flag, determines if contract's bytecode was modified
  * `bytecode_checked_at` - timestamp of the last check of contract's bytecode matching (DB and BlockChain)
  * `contract_code_md5` - md5(`t:Explorer.Chain.Address.t/0` `contract_code`)
  * `compiler_settings` - raw compilation parameters
  * `autodetect_constructor_args` - field was added for storing user's choice
  * `is_yul` - field was added for storing user's choice
  * `certified` - boolean flag, which can be set for set of smart-contracts via runtime env variable to prioritize those smart-contracts in the search.
  * `is_blueprint` - boolean flag, determines if contract is ERC-5202 compatible blueprint contract or not.
  """
  Explorer.Chain.SmartContract.Schema.generate()

  def preload_decompiled_smart_contract(contract) do
    Repo.preload(contract, :decompiled_smart_contracts)
  end

  def changeset(%__MODULE__{} = smart_contract, attrs) do
    attrs_to_cast =
      @required_attrs ++
        @optional_common_attrs ++
        @optional_changeset_attrs ++
        @chain_type_optional_attrs

    required_for_validation = [:name, :contract_source_code] ++ @required_attrs

    smart_contract
    |> cast(attrs, attrs_to_cast)
    |> validate_required(required_for_validation)
    |> unique_constraint(:address_hash)
    |> prepare_changes(&upsert_contract_methods/1)
  end

  def invalid_contract_changeset(
        %__MODULE__{} = smart_contract,
        attrs,
        error,
        error_message,
        verification_with_files? \\ false
      ) do
    attrs_to_cast =
      @required_attrs ++
        @optional_common_attrs ++
        @optional_invalid_contract_changeset_attrs ++
        @chain_type_optional_attrs

    validated =
      smart_contract
      |> cast(attrs, attrs_to_cast)
      |> (&if(verification_with_files?,
            do: &1,
            else: validate_required(&1, @required_attrs)
          )).()

    field_to_put_message = if verification_with_files?, do: :files, else: select_error_field(error)

    if error_message do
      add_error(validated, field_to_put_message, error_message(error, error_message))
    else
      add_error(validated, field_to_put_message, error_message(error))
    end
  end

  def add_submitted_comment(code, inserted_at) when is_binary(code) do
    code
    |> String.split("\n")
    |> add_submitted_comment(inserted_at)
    |> Enum.join("\n")
  end

  def add_submitted_comment(contract_lines, inserted_at) when is_list(contract_lines) do
    etherscan_index =
      Enum.find_index(contract_lines, fn line ->
        String.contains?(line, "Submitted for verification at Etherscan.io")
      end)

    blockscout_index =
      Enum.find_index(contract_lines, fn line ->
        String.contains?(line, "Submitted for verification at blockscout.com")
      end)

    cond do
      etherscan_index && blockscout_index ->
        List.replace_at(contract_lines, etherscan_index, "*")

      etherscan_index && !blockscout_index ->
        List.replace_at(
          contract_lines,
          etherscan_index,
          "* Submitted for verification at blockscout.com on #{inserted_at}"
        )

      !etherscan_index && !blockscout_index ->
        header = ["/**", "* Submitted for verification at blockscout.com on #{inserted_at}", "*/"]

        header ++ contract_lines

      true ->
        contract_lines
    end
  end

  def merge_twin_contract_with_changeset(%__MODULE__{} = twin_contract, %Changeset{} = changeset) do
    %__MODULE__{}
    |> changeset(Map.from_struct(twin_contract))
    |> Changeset.put_change(:autodetect_constructor_args, true)
    |> Changeset.put_change(:is_yul, false)
    |> Changeset.force_change(:address_hash, Changeset.get_field(changeset, :address_hash))
  end

  def merge_twin_contract_with_changeset(nil, %Changeset{} = changeset) do
    optimization_runs =
      if Application.get_env(:explorer, :chain_type) == :zksync,
        do: "0",
        else: "200"

    changeset
    |> Changeset.put_change(:name, "")
    |> Changeset.put_change(:optimization_runs, optimization_runs)
    |> Changeset.put_change(:optimization, true)
    |> Changeset.put_change(:evm_version, "default")
    |> Changeset.put_change(:compiler_version, "latest")
    |> Changeset.put_change(:contract_source_code, "")
    |> Changeset.put_change(:autodetect_constructor_args, true)
    |> Changeset.put_change(:is_yul, false)
    |> (&if(Application.get_env(:explorer, :chain_type) == :zksync,
          do: Changeset.put_change(&1, :zk_compiler_version, "latest"),
          else: &1
        )).()
  end

  def merge_twin_vyper_contract_with_changeset(
        %__MODULE__{is_vyper_contract: true} = twin_contract,
        %Changeset{} = changeset
      ) do
    %__MODULE__{}
    |> changeset(Map.from_struct(twin_contract))
    |> Changeset.force_change(:address_hash, Changeset.get_field(changeset, :address_hash))
  end

  def merge_twin_vyper_contract_with_changeset(%__MODULE__{is_vyper_contract: false}, %Changeset{} = changeset) do
    merge_twin_vyper_contract_with_changeset(nil, changeset)
  end

  def merge_twin_vyper_contract_with_changeset(%__MODULE__{is_vyper_contract: nil}, %Changeset{} = changeset) do
    merge_twin_vyper_contract_with_changeset(nil, changeset)
  end

  def merge_twin_vyper_contract_with_changeset(nil, %Changeset{} = changeset) do
    changeset
    |> Changeset.put_change(:name, "Vyper_contract")
    |> Changeset.put_change(:compiler_version, "latest")
    |> Changeset.put_change(:contract_source_code, "")
    |> (&if(Application.get_env(:explorer, :chain_type) == :zksync,
          do: Changeset.put_change(&1, :zk_compiler_version, "latest"),
          else: &1
        )).()
  end

  def license_types_enum, do: @license_enum

  @doc """
  Returns smart-contract changeset with checksummed address hash
  """
  @spec address_to_checksum_address(Changeset.t()) :: Changeset.t()
  def address_to_checksum_address(changeset) do
    checksum_address =
      changeset
      |> Changeset.get_field(:address_hash)
      |> to_address_hash()
      |> Address.checksum()

    Changeset.force_change(changeset, :address_hash, checksum_address)
  end

  @doc """
  Returns SmartContract by the given smart-contract address hash, if it is partially verified
  """
  @spec select_partially_verified_by_address_hash(binary() | Hash.t(), keyword) :: boolean() | nil
  def select_partially_verified_by_address_hash(address_hash_string, options \\ []) do
    query =
      from(
        smart_contract in __MODULE__,
        where: smart_contract.address_hash == ^address_hash_string,
        select: smart_contract.partially_verified
      )

    Chain.select_repo(options).one(query)
  end

  @doc """
    Extracts creation bytecode (`init`) and transaction (`tx`) or
      internal transaction (`internal_transaction`) where the contract was created.
  """
  @spec creation_transaction_with_bytecode(binary() | Hash.t()) ::
          %{init: binary(), transaction: Transaction.t()}
          | %{init: binary(), internal_transaction: InternalTransaction.t()}
          | nil
  def creation_transaction_with_bytecode(address_hash) do
    creation_transaction_query =
      from(
        transaction in Transaction,
        where: transaction.created_contract_address_hash == ^address_hash,
        where: transaction.status == ^1,
        order_by: [desc: transaction.block_number],
        limit: ^1
      )

    transaction =
      creation_transaction_query
      |> Repo.one()

    if transaction do
      with %{input: input} <- transaction do
        %{init: Data.to_string(input), transaction: transaction}
      end
    else
      creation_int_transaction_query =
        from(
          itx in InternalTransaction,
          join: t in assoc(itx, :transaction),
          where: itx.created_contract_address_hash == ^address_hash,
          where: t.status == ^1
        )

      internal_transaction = creation_int_transaction_query |> Repo.one()

      case internal_transaction do
        %{init: init} ->
          init_str = Data.to_string(init)
          %{init: init_str, internal_transaction: internal_transaction}

        _ ->
          nil
      end
    end
  end

  @doc """
  Composes address object for unverified smart-contract
  """
  @spec compose_address_for_unverified_smart_contract(map(), any()) :: map()
  def compose_address_for_unverified_smart_contract(%{smart_contract: smart_contract} = address_result, options)
      when is_nil(smart_contract) do
    smart_contract = %{
      updated: %__MODULE__{
        address_hash: address_result.hash
      },
      implementation_updated_at: nil,
      implementation_address_fetched?: false,
      refetch_necessity_checked?: false
    }

    {implementation_address_hash, _names, _proxy_type} =
      Implementation.get_implementation(
        smart_contract,
        Keyword.put(options, :proxy_without_abi?, true)
      )

    implementation_smart_contract =
      implementation_address_hash
      |> Proxy.implementation_to_smart_contract(options)

    address_verified_bytecode_twin_contract =
      implementation_smart_contract ||
        get_address_verified_bytecode_twin_contract(address_result.hash, options).verified_contract

    if address_verified_bytecode_twin_contract do
      add_bytecode_twin_info_to_contract(address_result, address_verified_bytecode_twin_contract, address_result.hash)
    else
      address_result
    end
  end

  def compose_address_for_unverified_smart_contract(address_result, _hash, _options), do: address_result

  def single_implementation_smart_contract_from_proxy(proxy_hash, options) do
    {implementation_address_hashes, _names, _proxy_type} = Implementation.get_implementation(proxy_hash, options)

    if implementation_address_hashes && Enum.count(implementation_address_hashes) == 1 do
      implementation_address_hashes
      |> Enum.at(0)
      |> Proxy.implementation_to_smart_contract(options)
    else
      nil
    end
  end

  @doc """
  Finds metadata for verification of a contract from verified twins: contracts with the same bytecode
  which were verified previously, returns a single t:SmartContract.t/0
  """
  @spec get_address_verified_bytecode_twin_contract(Hash.t() | String.t(), any()) :: %{
          :verified_contract => any(),
          :additional_sources => SmartContractAdditionalSource.t() | nil
        }
  def get_address_verified_bytecode_twin_contract(hash, options \\ [])

  def get_address_verified_bytecode_twin_contract(hash, options) when is_binary(hash) do
    case Chain.string_to_address_hash(hash) do
      {:ok, address_hash} -> get_address_verified_bytecode_twin_contract(address_hash, options)
      _ -> %{:verified_contract => nil, :additional_sources => nil}
    end
  end

  def get_address_verified_bytecode_twin_contract(%Hash{} = address_hash, options) do
    with target_address <- Chain.select_repo(options).get(Address, address_hash),
         false <- is_nil(target_address) do
      verified_bytecode_twin_contract = get_verified_bytecode_twin_contract(target_address, options)

      verified_bytecode_twin_contract_additional_sources =
        SmartContractAdditionalSource.get_contract_additional_sources(verified_bytecode_twin_contract, options)

      %{
        :verified_contract => check_and_update_constructor_args(verified_bytecode_twin_contract),
        :additional_sources => verified_bytecode_twin_contract_additional_sources
      }
    else
      _ ->
        %{:verified_contract => nil, :additional_sources => nil}
    end
  end

  @doc """
  Returns verified smart-contract with the same bytecode of the given smart-contract
  """
  @spec get_verified_bytecode_twin_contract(Address.t(), any()) :: SmartContract.t() | nil
  def get_verified_bytecode_twin_contract(%Address{} = target_address, options \\ []) do
    necessity_by_association = %{
      :smart_contract_additional_sources => :optional
    }

    case target_address do
      %{contract_code: %Chain.Data{bytes: contract_code_bytes}} ->
        target_address_hash = target_address.hash

        contract_code_md5 = Helper.contract_code_md5(contract_code_bytes)

        verified_bytecode_twin_contract_query =
          from(
            smart_contract in __MODULE__,
            where: smart_contract.contract_code_md5 == ^contract_code_md5,
            where: smart_contract.address_hash != ^target_address_hash,
            select: smart_contract,
            limit: 1
          )

        verified_bytecode_twin_contract_query
        |> Chain.join_associations(necessity_by_association)
        |> Chain.select_repo(options).one(timeout: 10_000)

      _ ->
        nil
    end
  end

  @doc """
  Returns address or smart_contract object with parsed constructor_arguments
  """
  @spec check_and_update_constructor_args(any()) :: any()
  def check_and_update_constructor_args(
        %__MODULE__{address_hash: address_hash, constructor_arguments: nil, verified_via_sourcify: true} =
          smart_contract
      ) do
    if args = Verifier.parse_constructor_arguments_for_sourcify_contract(address_hash, smart_contract.abi) do
      smart_contract |> __MODULE__.changeset(%{constructor_arguments: args}) |> Repo.update()
      %__MODULE__{smart_contract | constructor_arguments: args}
    else
      smart_contract
    end
  end

  def check_and_update_constructor_args(
        %Address{
          hash: address_hash,
          contract_code: deployed_bytecode,
          smart_contract: %__MODULE__{constructor_arguments: nil, verified_via_sourcify: true} = smart_contract
        } = address
      ) do
    if args =
         Verifier.parse_constructor_arguments_for_sourcify_contract(address_hash, smart_contract.abi, deployed_bytecode) do
      smart_contract |> __MODULE__.changeset(%{constructor_arguments: args}) |> Repo.update()
      %Address{address | smart_contract: %__MODULE__{smart_contract | constructor_arguments: args}}
    else
      address
    end
  end

  def check_and_update_constructor_args(other), do: other

  @doc """
  Adds verified metadata from bytecode twin smart-contract to the given smart-contract
  """
  @spec add_bytecode_twin_info_to_contract(map(), SmartContract.t(), Hash.Address.t() | nil) :: map()
  def add_bytecode_twin_info_to_contract(address_result, nil, _hash), do: address_result

  def add_bytecode_twin_info_to_contract(address_result, address_verified_bytecode_twin_contract, hash) do
    address_verified_bytecode_twin_contract_updated =
      put_from_verified_twin(address_verified_bytecode_twin_contract, hash)

    address_result
    |> Map.put(:smart_contract, address_verified_bytecode_twin_contract_updated)
  end

  @doc """
    Inserts a new smart contract and associated data into the database.

    This function creates a new smart contract entry in the database. It calculates an MD5 hash of
    the contract's bytecode, upserts contract methods, and handles the linkage of external libraries and
    additional secondary sources. It also updates the associated address to mark the contract as
    verified and manages the naming records for the address.

    ## Parameters
    - `attrs`: Attributes for the new smart contract.
    - `external_libraries`: A list of external libraries used by the contract.
    - `secondary_sources`: Additional source data related to the contract.

    ## Returns
    - `{:ok, smart_contract}` on successful insertion.
    - `{:error, data}` on failure, returning the changeset or, if any issues happen during setting the address as verified, an error message.
  """
  @spec create_smart_contract(map(), list(), list()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t()}
  def create_smart_contract(attrs \\ %{}, external_libraries \\ [], secondary_sources \\ []) do
    new_contract = %__MODULE__{}

    # Updates contract attributes with calculated MD5 for the contract's bytecode
    attrs =
      attrs
      |> Helper.add_contract_code_md5()

    # Prepares changeset and extends it with external libraries.
    # As part of changeset preparation and verification, contract methods are upserted
    smart_contract_changeset =
      new_contract
      |> __MODULE__.changeset(attrs)
      |> Changeset.put_change(:external_libraries, external_libraries)

    # Prepares changesets for additional sources associated with the contract
    new_contract_additional_source = %SmartContractAdditionalSource{}

    smart_contract_additional_sources_changesets =
      if secondary_sources do
        secondary_sources
        |> Enum.map(fn changeset ->
          new_contract_additional_source
          |> SmartContractAdditionalSource.changeset(changeset)
        end)
      else
        []
      end

    address_hash = Changeset.get_field(smart_contract_changeset, :address_hash)

    # Prepares the queries to update Explorer.Chain.Address to mark the contract as
    # verified, clear the primary flag for the contract address in
    # Explorer.Chain.Address.Name if any (enforce ShareLocks tables order (see
    # docs: sharelocks.md)) and insert the contract details.
    insert_contract_query =
      Multi.new()
      |> Multi.run(:set_address_verified, fn repo, _ -> set_address_verified(repo, address_hash) end)
      |> Multi.run(:clear_primary_address_names, fn repo, _ ->
        AddressName.clear_primary_address_names(repo, address_hash)
      end)
      |> Multi.insert(:smart_contract, smart_contract_changeset)

    # Updates the queries from the previous step with inserting additional sources
    # of the contract
    insert_contract_query_with_additional_sources =
      smart_contract_additional_sources_changesets
      |> Enum.with_index()
      |> Enum.reduce(insert_contract_query, fn {changeset, index}, multi ->
        Multi.insert(multi, "smart_contract_additional_source_#{Integer.to_string(index)}", changeset)
      end)

    # Applying the queries to the database
    insert_result =
      insert_contract_query_with_additional_sources
      |> Repo.transaction()

    # Set the primary mark for the contract name
    AddressName.create_primary_address_name(Repo, Changeset.get_field(smart_contract_changeset, :name), address_hash)

    case insert_result do
      {:ok, %{smart_contract: smart_contract}} ->
        {:ok, smart_contract}

      {:error, :smart_contract, changeset, _} ->
        {:error, changeset}

      {:error, :set_address_verified, message, _} ->
        {:error, message}
    end
  end

  @doc """
    Updates an existing smart contract and associated data into the database.

    This function is similar to `create_smart_contract/1` but is used for updating an existing smart
    contract, such as changing its verification status from `partially verified` to `fully verified`.
    It handles the updates including external libraries and secondary sources associated with the contract.
    Notably, it updates contract methods based on the new ABI provided: if the new ABI does not contain
    some of the previously listed methods, those methods are retained in the database.

    ## Parameters
    - `attrs`: Attributes for the smart contract to be updated.
    - `external_libraries`: A list of external libraries associated with the contract.
    - `secondary_sources`: A list of secondary source data associated with the contract.

    ## Returns
    - `{:ok, smart_contract}` on successful update.
    - `{:error, changeset}` on failure, indicating issues with the data provided for update.
  """
  @spec update_smart_contract(map(), list(), list()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t()}
  def update_smart_contract(attrs \\ %{}, external_libraries \\ [], secondary_sources \\ []) do
    address_hash = Map.get(attrs, :address_hash)

    # Removes all additional sources associated with the contract
    query_sources =
      from(
        source in SmartContractAdditionalSource,
        where: source.address_hash == ^address_hash
      )

    _delete_sources = Repo.delete_all(query_sources)

    # Retrieve the existing smart contract
    query = get_smart_contract_query(address_hash)
    smart_contract = Repo.one(query)

    # Updates existing changeset and extends it with external libraries.
    # As part of changeset preparation and verification, contract methods are
    # updated as so if new ABI does not contain some of previous methods, they
    # are still kept in the database
    smart_contract_changeset =
      smart_contract
      |> __MODULE__.changeset(attrs)
      |> Changeset.put_change(:external_libraries, external_libraries)

    # Prepares changesets for additional sources associated with the contract
    new_contract_additional_source = %SmartContractAdditionalSource{}

    smart_contract_additional_sources_changesets =
      if secondary_sources do
        secondary_sources
        |> Enum.map(fn changeset ->
          new_contract_additional_source
          |> SmartContractAdditionalSource.changeset(changeset)
        end)
      else
        []
      end

    # Prepares the queries to clear the primary flag for the contract address in
    # Explorer.Chain.Address.Name if any (enforce ShareLocks tables order (see
    # docs: sharelocks.md)) and updated the contract details.
    insert_contract_query =
      Multi.new()
      |> Multi.run(:clear_primary_address_names, fn repo, _ ->
        AddressName.clear_primary_address_names(repo, address_hash)
      end)
      |> Multi.update(:smart_contract, smart_contract_changeset)

    # Updates the queries from the previous step with inserting additional sources
    # of the contract
    insert_contract_query_with_additional_sources =
      smart_contract_additional_sources_changesets
      |> Enum.with_index()
      |> Enum.reduce(insert_contract_query, fn {changeset, index}, multi ->
        Multi.insert(multi, "smart_contract_additional_source_#{Integer.to_string(index)}", changeset)
      end)

    # Applying the queries to the database
    insert_result =
      insert_contract_query_with_additional_sources
      |> Repo.transaction()

    # Set the primary mark for the contract name
    AddressName.create_primary_address_name(Repo, Changeset.get_field(smart_contract_changeset, :name), address_hash)

    case insert_result do
      {:ok, %{smart_contract: smart_contract}} ->
        {:ok, smart_contract}

      {:error, :smart_contract, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Converts address hash to smart-contract object
  """
  @spec address_hash_to_smart_contract(Hash.Address.t(), [api?]) :: __MODULE__.t() | nil
  def address_hash_to_smart_contract(address_hash, options) do
    query = get_smart_contract_query(address_hash)

    Chain.select_repo(options).one(query)
  end

  @doc """
  Converts address hash to smart-contract object with metadata_from_verified_bytecode_twin=true
  """
  @spec address_hash_to_smart_contract_with_bytecode_twin(Hash.Address.t(), [api?]) :: {__MODULE__.t() | nil, boolean()}
  def address_hash_to_smart_contract_with_bytecode_twin(address_hash, options \\ [], fetch_implementation? \\ true) do
    current_smart_contract = address_hash_to_smart_contract(address_hash, options)

    with true <- is_nil(current_smart_contract),
         {:ok, address} <- Chain.hash_to_address(address_hash),
         true <- Address.smart_contract?(address) do
      {implementation_smart_contract, implementation_address_fetched?} =
        if fetch_implementation? do
          implementation_smart_contract =
            SmartContract.single_implementation_smart_contract_from_proxy(
              %{
                updated: %SmartContract{
                  address_hash: address_hash,
                  abi: nil
                },
                implementation_updated_at: nil,
                implementation_address_fetched?: false,
                refetch_necessity_checked?: false
              },
              Keyword.put(options, :proxy_without_abi?, true)
            )

          {implementation_smart_contract, true}
        else
          {nil, false}
        end

      address_verified_bytecode_twin_contract =
        implementation_smart_contract ||
          get_address_verified_bytecode_twin_contract(address_hash, options).verified_contract

      smart_contract =
        if address_verified_bytecode_twin_contract do
          put_from_verified_twin(address_verified_bytecode_twin_contract, address_hash)
        else
          nil
        end

      {smart_contract, implementation_address_fetched?}
    else
      _ ->
        {current_smart_contract, false}
    end
  end

  defp put_from_verified_twin(address_verified_bytecode_twin_contract, address_hash) do
    address_verified_bytecode_twin_contract
    |> Map.put(:address_hash, address_hash)
    |> Map.put(:metadata_from_verified_bytecode_twin, true)
  end

  @doc """
  Checks if it exists a verified `t:Explorer.Chain.SmartContract.t/0` for the
  `t:Explorer.Chain.Address.t/0` with the provided `hash` and `partially_verified` property is not true.

  Returns `true` if found and `false` otherwise.
  """
  @spec verified_with_full_match?(Hash.Address.t() | String.t()) :: boolean()
  def verified_with_full_match?(address_hash, options \\ [])

  def verified_with_full_match?(address_hash_string, options) when is_binary(address_hash_string) do
    case Chain.string_to_address_hash(address_hash_string) do
      {:ok, address_hash} ->
        check_verified_with_full_match(address_hash, options)

      _ ->
        false
    end
  end

  def verified_with_full_match?(address_hash, options) do
    check_verified_with_full_match(address_hash, options)
  end

  @doc """
    Checks if a `Explorer.Chain.SmartContract` exists for the provided address hash.

    ## Parameters
    - `address_hash_string` or `address_hash`: The hash of the address in binary string
                                            form or directly as an address hash.

    ## Returns
    - `boolean()`: `true` if a smart contract exists, `false` otherwise.
  """
  @spec verified?(Hash.Address.t() | String.t()) :: boolean()
  def verified?(address_hash_string) when is_binary(address_hash_string) do
    case Chain.string_to_address_hash(address_hash_string) do
      {:ok, address_hash} ->
        verified_smart_contract_exists?(address_hash)

      _ ->
        false
    end
  end

  def verified?(address_hash) do
    verified_smart_contract_exists?(address_hash)
  end

  @doc """
  Checks if it exists a verified `t:Explorer.Chain.SmartContract.t/0` for the
  `t:Explorer.Chain.Address.t/0` with the provided `hash`.

  Returns `:ok` if found and `:not_found` otherwise.
  """
  @spec check_verified_smart_contract_exists(Hash.Address.t()) :: :ok | :not_found
  def check_verified_smart_contract_exists(address_hash) do
    address_hash
    |> verified_smart_contract_exists?()
    |> Chain.boolean_to_check_result()
  end

  @doc """
  Gets smart-contract ABI from the DB for the given address hash of smart-contract
  """
  @spec get_smart_contract_abi(String.t(), any()) :: any()
  def get_smart_contract_abi(address_hash_string, options \\ [])

  def get_smart_contract_abi(address_hash_string, options)
      when not is_nil(address_hash_string) do
    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {smart_contract, _} =
           address_hash
           |> address_hash_to_smart_contract_with_bytecode_twin(options, false),
         false <- is_nil(smart_contract) do
      smart_contract
      |> Map.get(:abi)
    else
      _ ->
        []
    end
  end

  def get_smart_contract_abi(address_hash_string, _) when is_nil(address_hash_string) do
    []
  end

  @doc """
    Composes a query for fetching a smart contract by its address hash.

    ## Parameters
    - `address_hash`: The hash of the smart contract's address.

    ## Returns
    - An `Ecto.Query.t()` that represents the query to fetch the smart contract.
  """
  @spec get_smart_contract_query(Hash.Address.t() | binary) :: Ecto.Query.t()
  def get_smart_contract_query(address_hash) do
    from(
      smart_contract in __MODULE__,
      where: smart_contract.address_hash == ^address_hash
    )
  end

  defp upsert_contract_methods(%Changeset{changes: %{abi: abi}} = changeset) do
    ContractMethod.upsert_from_abi(abi, get_field(changeset, :address_hash))

    changeset
  rescue
    exception ->
      message = Exception.format(:error, exception, __STACKTRACE__)

      Logger.error(fn -> ["Error while upserting contract methods: ", message] end)

      changeset
  end

  defp upsert_contract_methods(changeset), do: changeset

  defp error_message(:compilation), do: error_message_with_log("There was an error compiling your contract.")

  defp error_message(:compiler_version),
    do: error_message_with_log("Compiler version does not match, please try again.")

  defp error_message(:generated_bytecode), do: error_message_with_log("Bytecode does not match, please try again.")

  defp error_message(:constructor_arguments),
    do: error_message_with_log("Constructor arguments do not match, please try again.")

  defp error_message(:name), do: error_message_with_log("Wrong contract name, please try again.")
  defp error_message(:json), do: error_message_with_log("Invalid JSON file.")

  defp error_message(:autodetect_constructor_arguments_failed),
    do:
      error_message_with_log(
        "Autodetection of constructor arguments failed. Please try to input constructor arguments manually."
      )

  defp error_message(:no_creation_data),
    do:
      error_message_with_log(
        "The contract creation transaction has not been indexed yet. Please wait a few minutes and try again."
      )

  defp error_message(:unknown_error), do: error_message_with_log("Unable to verify: unknown error.")

  defp error_message(:deployed_bytecode),
    do: error_message_with_log("Deployed bytecode does not correspond to contract creation code.")

  defp error_message(:contract_source_code), do: error_message_with_log("Empty contract source code.")

  defp error_message(string) when is_binary(string), do: error_message_with_log(string)
  defp error_message(%{"message" => string} = error) when is_map(error), do: error_message_with_log(string)

  defp error_message(error) do
    Logger.warning(fn -> ["Unknown verifier error: ", inspect(error)] end)
    "There was an error validating your contract, please try again."
  end

  defp error_message(:compilation, error_message),
    do: error_message_with_log("There was an error compiling your contract: #{error_message}")

  defp error_message_with_log(error_string) do
    Logger.error("Smart-contract verification error: #{error_string}")
    error_string
  end

  defp select_error_field(:no_creation_data), do: :address_hash
  defp select_error_field(:compiler_version), do: :compiler_version

  defp select_error_field(constructor_arguments)
       when constructor_arguments in [:constructor_arguments, :autodetect_constructor_arguments_failed],
       do: :constructor_arguments

  defp select_error_field(:name), do: :name
  defp select_error_field(_), do: :contract_source_code

  defp to_address_hash(string) when is_binary(string) do
    {:ok, address_hash} = Chain.string_to_address_hash(string)
    address_hash
  end

  defp to_address_hash(address_hash), do: address_hash

  # Checks if a smart contract exists in `Explorer.Chain.SmartContract` for a given
  # address hash.
  @spec verified_smart_contract_exists?(Hash.Address.t()) :: boolean()
  defp verified_smart_contract_exists?(address_hash) do
    query = get_smart_contract_query(address_hash)

    Repo.exists?(query)
  end

  defp set_address_verified(repo, address_hash) do
    query =
      from(
        address in Address,
        where: address.hash == ^address_hash
      )

    case repo.update_all(query, set: [verified: true]) do
      {1, _} -> {:ok, []}
      _ -> {:error, "There was an error annotating that the address has been verified."}
    end
  end

  @doc """
  Sets smart-contract certified flag
  """
  @spec set_smart_contracts_certified_flag(list()) ::
          {:ok, []} | {:error, String.t()}
  def set_smart_contracts_certified_flag([]), do: {:ok, []}

  def set_smart_contracts_certified_flag(address_hashes) do
    query =
      from(
        contract in __MODULE__,
        where: contract.address_hash in ^address_hashes
      )

    case Repo.update_all(query, set: [certified: true]) do
      {1, _} -> {:ok, []}
      _ -> {:error, "There was an error in setting certified flag."}
    end
  end

  defp check_verified_with_full_match(address_hash, options) do
    smart_contract = address_hash_to_smart_contract(address_hash, options)

    if smart_contract, do: !smart_contract.partially_verified, else: false
  end

  @spec verified_contracts([
          Chain.paging_options()
          | Chain.necessity_by_association_option()
          | {:filter, :solidity | :vyper | :yul}
          | {:search, String.t()}
          | {:sorting, SortingHelper.sorting_params()}
          | Chain.api?()
        ]) :: [__MODULE__.t()]
  def verified_contracts(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())
    sorting_options = Keyword.get(options, :sorting, [])
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    filter = Keyword.get(options, :filter, nil)
    search_string = Keyword.get(options, :search, nil)

    query = from(contract in __MODULE__)

    query
    |> ExplorerHelper.maybe_hide_scam_addresses(:address_hash)
    |> filter_contracts(filter)
    |> search_contracts(search_string)
    |> SortingHelper.apply_sorting(sorting_options, @default_sorting)
    |> SortingHelper.page_with_sorting(paging_options, sorting_options, @default_sorting)
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).all()
  end

  defp search_contracts(basic_query, nil), do: basic_query

  defp search_contracts(basic_query, search_string) do
    from(contract in basic_query,
      where:
        ilike(contract.name, ^"%#{search_string}%") or
          ilike(fragment("'0x' || encode(?, 'hex')", contract.address_hash), ^"%#{search_string}%")
    )
  end

  defp filter_contracts(basic_query, :solidity) do
    basic_query
    |> where(is_vyper_contract: ^false)
  end

  defp filter_contracts(basic_query, :vyper) do
    basic_query
    |> where(is_vyper_contract: ^true)
  end

  defp filter_contracts(basic_query, :yul) do
    from(query in basic_query, where: is_nil(query.abi))
  end

  defp filter_contracts(basic_query, _), do: basic_query

  @doc """
  Retrieves the constructor arguments for a zkSync smart contract.
  Using @create_zksync_abi function decodes transaction input of contract creation

  ## Parameters
  - `binary()`: The binary data representing the smart contract.

  ## Returns
  - `nil`: If the constructor arguments cannot be retrieved.
  - `binary()`: The constructor arguments in binary format.
  """
  @spec zksync_get_constructor_arguments(binary()) :: nil | binary()
  def zksync_get_constructor_arguments(address_hash_string) do
    creation_input = Chain.contract_creation_input_data_from_transaction(address_hash_string)

    case @create_zksync_abi |> ABI.parse_specification() |> ABI.find_and_decode(creation_input) do
      {%FunctionSelector{}, [_, _, constructor_args]} ->
        Base.encode16(constructor_args, case: :lower)

      _ ->
        nil
    end
  end
end
