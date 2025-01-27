import dateutil
import pytest
from typing import Callable

from pbench.server.api.auth import Auth, UnknownUser
from pbench.server.api.resources.query_apis import (
    ParamType,
    ConversionError,
    InvalidRequestPayload,
    MissingParameters,
    Parameter,
    Schema,
)


class TestParamType:
    """
    Tests on the ParamType enum
    """

    def test_enum(self):
        assert (
            len(ParamType.__members__) == 4
        ), "Number of ParamType ENUM values has changed; confirm test coverage!"
        for n, t in ParamType.__members__.items():
            assert str(t) == t.friendly.upper()
            assert isinstance(t.convert, Callable)

    @pytest.mark.parametrize(
        "test",
        (
            (ParamType.STRING, "x", "x"),
            (ParamType.JSON, {"key": "value"}, {"key": "value"}),
            (ParamType.DATE, "2021-06-29", dateutil.parser.parse("2021-06-29")),
            (ParamType.USER, "drb", "drb"),
        ),
    )
    def test_successful_conversions(self, test, monkeypatch):
        def ok(user: str) -> str:
            return user

        monkeypatch.setattr(Auth, "validate_user", ok)

        ptype, value, expected = test
        result = ptype.convert(value)
        assert result == expected

    @pytest.mark.parametrize(
        "test",
        (
            (ParamType.STRING, {"not": "string"}),
            (ParamType.JSON, "not_json"),
            (ParamType.DATE, "2021-06-45"),
            (ParamType.USER, "drb"),
        ),
    )
    def test_failed_conversions(self, test, monkeypatch):
        def not_ok(user: str) -> str:
            raise UnknownUser()

        monkeypatch.setattr(Auth, "validate_user", not_ok)

        ptype, value = test
        with pytest.raises(ConversionError) as exc:
            ptype.convert(value)
        assert str(exc).find(str(value))


class TestParameter:
    """
    Tests on the Parameter class
    """

    def test_constructor(self):
        x = Parameter("test", ParamType.STRING)
        assert not x.required
        assert x.name == "test"
        assert x.type is ParamType.STRING

        y = Parameter("foo", ParamType.JSON, required=True)
        assert y.required
        assert y.name == "foo"
        assert y.type is ParamType.JSON

    @pytest.mark.parametrize(
        "test",
        (
            ({"data": "yes"}, False),
            ({"data": None}, True),
            ({"foo": "yes"}, True),
            ({"foo": None, "data": "yes"}, False),
        ),
    )
    def test_invalid_required(self, test):
        x = Parameter("data", ParamType.STRING, required=True)
        json, expected = test
        assert x.invalid(json) is expected

    @pytest.mark.parametrize(
        "test",
        (
            ({"data": "yes"}, False),
            ({"data": None}, True),
            ({"foo": "yes"}, False),
            ({"foo": None}, False),
        ),
    )
    def test_invalid_optional(self, test):
        x = Parameter("data", ParamType.STRING)
        json, expected = test
        assert x.invalid(json) is expected


class TestSchema:
    """
    Tests on the Schema class
    """

    schema = Schema(
        Parameter("key1", ParamType.STRING, required=True),
        Parameter("key2", ParamType.JSON),
        Parameter("key3", ParamType.DATE),
    )

    def test_bad_payload(self):
        with pytest.raises(InvalidRequestPayload):
            self.schema.validate(None)

    def test_missing_required(self):
        with pytest.raises(MissingParameters):
            self.schema.validate({"key2": "abc"})

    def test_missing_optional(self):
        test = {"key1": "OK"}
        assert test == self.schema.validate(test)

    def test_bad_dates(self):
        with pytest.raises(ConversionError):
            self.schema.validate({"key1": "yes", "key3": "2000-02-56"})

    def test_bad_json(self):
        with pytest.raises(ConversionError):
            self.schema.validate({"key1": 1, "key2": "not JSON"})

    def test_all_clear(self):
        payload = {
            "key1": "name",
            "key3": "2021-06-29",
            "key2": {"json": True, "key": "abc"},
        }
        expected = payload.copy()
        expected["key3"] = dateutil.parser.parse(expected["key3"])
        assert expected == self.schema.validate(payload)
