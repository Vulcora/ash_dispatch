defmodule AshDispatch.SampleVariablesTest do
  @moduledoc """
  `c:AshDispatch.Event.sample_data/1` may answer the data and the template
  variables.

  A preview never runs `generate_send_variables/2` — that is where events mint
  reset tokens and invitation links — so a letter whose template prints such a
  variable had nowhere to get a plausible one. The only way round it was to
  smuggle the variables into `data` under a key and unpack them again on the
  rendering side, differently in every event that did it.

  The old form must keep working untouched, and the two must be told apart
  without guessing, so both halves are pinned here.
  """
  use AshDispatch.Test.PreviewCase, async: false

  alias AshDispatch.EventResolver
  alias AshDispatch.Preview
  alias AshDispatch.Test.Preview.BookingMinted
  alias AshDispatch.Test.Preview.BookingReminder

  @moduletag :capture_log

  describe "EventResolver.sample/2" do
    test "splits the new form" do
      assert %{data: data, variables: variables} = EventResolver.sample(BookingMinted, seed: 0)

      assert %{booking: %{reference: "B-MINTED"}} = data
      assert variables == %{reset_url: "https://example.test/reset/sample-token"}
    end

    test "answers the old form as data with no variables" do
      assert %{data: data, variables: %{}} = EventResolver.sample(BookingReminder, seed: 0)

      assert %{booking: %{reference: "B-SAMPLE"}} = data
    end

    test "an event with no sample data at all answers two empty maps" do
      defmodule NoSample do
        @moduledoc false
      end

      assert EventResolver.sample(NoSample, seed: 0) == %{data: %{}, variables: %{}}
    end

    test "a keyword list of variables is taken as a map" do
      defmodule KeywordVariables do
        @moduledoc false
        def sample_data(_opts), do: %{data: %{a: 1}, variables: [token: "t"]}
      end

      assert %{variables: %{token: "t"}} = EventResolver.sample(KeywordVariables, seed: 0)
    end
  end

  describe "telling the two forms apart" do
    test "data whose own key is :data beside others is the OLD form" do
      defmodule DataKeyBesideOthers do
        @moduledoc false
        # A perfectly ordinary event whose record happens to be called `data`.
        def sample_data(_opts), do: %{data: %{id: 1}, booking: %{id: 2}}
      end

      assert %{data: data, variables: %{}} = EventResolver.sample(DataKeyBesideOthers, seed: 0)
      assert data == %{data: %{id: 1}, booking: %{id: 2}}
    end

    test "a lone :data key whose value is a map is the NEW form" do
      defmodule LoneDataKey do
        @moduledoc false
        def sample_data(_opts), do: %{data: %{booking: %{id: 2}}}
      end

      assert %{data: %{booking: %{id: 2}}, variables: %{}} =
               EventResolver.sample(LoneDataKey, seed: 0)
    end

    test "a :data key whose value is not a map is the old form" do
      defmodule DataIsNotAMap do
        @moduledoc false
        def sample_data(_opts), do: %{data: "a string"}
      end

      assert %{data: %{data: "a string"}} = EventResolver.sample(DataIsNotAMap, seed: 0)
    end

    test "variables that are not a map or keyword list are no variables" do
      defmodule JunkVariables do
        @moduledoc false
        def sample_data(_opts), do: %{data: %{a: 1}, variables: "nope"}
      end

      assert %{data: %{a: 1}, variables: %{}} = EventResolver.sample(JunkVariables, seed: 0)
    end
  end

  describe "sample_data/1,2 still answer the data" do
    test "the new form is unwrapped for every caller that wants data" do
      assert %{booking: _} = EventResolver.sample_data(BookingMinted, seed: 0)
      refute Map.has_key?(EventResolver.sample_data(BookingMinted, seed: 0), :variables)
    end

    test "build_sample_context still reads sample_data/0 only, as it always did" do
      # Unchanged on purpose: it is what `Resources.EmailEvent` resolves its
      # channels against, and an event that defines only `sample_data/1` has
      # given it an empty map since that arity existed.
      context = EventResolver.build_sample_context("booking.minted", BookingMinted)

      assert context.data == %{}
      assert %{booking: _} = EventResolver.sample_data(BookingMinted, seed: 0)
    end
  end

  describe "Preview.render/3" do
    test "renders the sample variables into the letter" do
      assert {:ok, [letter]} = Preview.render("booking.minted", :sample, seed: 0)

      assert letter.error == nil
      assert letter.text_body =~ "https://example.test/reset/sample-token"
      assert letter.html_body =~ "https://example.test/reset/sample-token"
    end

    test "never mints the real one" do
      assert {:ok, [letter]} = Preview.render("booking.minted", :sample, seed: 0)

      refute letter.text_body =~ "REAL-TOKEN"
    end

    test "a caller's own :variables win over the event's" do
      assert {:ok, [letter]} =
               Preview.render("booking.minted", :sample,
                 seed: 0,
                 variables: %{reset_url: "https://example.test/reset/mine"}
               )

      assert letter.text_body =~ "/reset/mine"
      refute letter.text_body =~ "sample-token"
    end

    test "an event on the old form renders exactly as before" do
      assert {:ok, [letter]} =
               Preview.render("booking.reminder", :sample,
                 seed: 0,
                 transport: :email,
                 variant: nil
               )

      assert letter.error == nil
      assert letter.subject =~ "See you soon"
    end

    test "events/0 lists the event on the new form like any other" do
      rows = Enum.filter(Preview.events(), &(&1.event_id == "booking.minted"))

      assert [%{transport: :email, audience: :user}] = rows
    end
  end
end
