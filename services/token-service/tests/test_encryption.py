from app.encryption import encrypt_token, decrypt_token

TEST_KEY = "dGVzdC1rZXktMzItYnl0ZXMtZm9yLWFlczI1Ng=="


def test_encrypt_decrypt_round_trip():
    plaintext = "shpat_test_token_12345"
    ciphertext = encrypt_token(plaintext, TEST_KEY)
    assert ciphertext != plaintext
    assert decrypt_token(ciphertext, TEST_KEY) == plaintext


def test_different_plaintexts_produce_different_ciphertexts():
    a = encrypt_token("token_a", TEST_KEY)
    b = encrypt_token("token_b", TEST_KEY)
    assert a != b


def test_decrypt_with_wrong_key_fails():
    import pytest
    ciphertext = encrypt_token("secret", TEST_KEY)
    wrong_key = "d3Jvbmcta2V5LTMyLWJ5dGVzLWZvci1hZXMyNTY="
    with pytest.raises(Exception):
        decrypt_token(ciphertext, wrong_key)
