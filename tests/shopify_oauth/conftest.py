import pytest


@pytest.fixture
def client_secret():
    return "test_secret_key_for_hmac_validation"


@pytest.fixture
def valid_shop():
    return "test-store.myshopify.com"


@pytest.fixture
def invalid_shops():
    return [
        "evil.com",
        "test.notshopify.com",
        ".myshopify.com",
        "test store.myshopify.com",
        "test.myshopify.com.evil.com",
    ]
