import pytest
import asyncio
from app.services.token_manager import SingleFlight


class TestSingleFlight:
    @pytest.mark.asyncio
    async def test_concurrent_calls_only_execute_once(self):
        sf = SingleFlight()
        call_count = 0

        async def slow_fn():
            nonlocal call_count
            call_count += 1
            await asyncio.sleep(0.1)
            return "result"

        results = await asyncio.gather(
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
        )

        assert call_count == 1
        assert all(r == "result" for r in results)

    @pytest.mark.asyncio
    async def test_different_keys_execute_independently(self):
        sf = SingleFlight()
        calls = []

        async def fn(name):
            calls.append(name)
            return name

        await asyncio.gather(
            sf.do("a", lambda: fn("a")),
            sf.do("b", lambda: fn("b")),
        )
        assert sorted(calls) == ["a", "b"]

    @pytest.mark.asyncio
    async def test_exception_propagates_to_all_waiters(self):
        sf = SingleFlight()

        async def failing_fn():
            raise ValueError("boom")

        with pytest.raises(ValueError, match="boom"):
            await asyncio.gather(
                sf.do("key", failing_fn),
                sf.do("key", failing_fn),
            )
