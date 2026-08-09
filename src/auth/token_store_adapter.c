#include "token_store_adapter.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define TOKEN_MAGIC "GOTS"
#define TOKEN_VERSION 1
#define TOKEN_ENCRYPTED 1
#define TOKEN_NONCE_LENGTH 12
#define TOKEN_TAG_LENGTH 16
#define TOKEN_KEY_LENGTH 32
#define TOKEN_FILE_LIMIT (64 * 1024)

static uint32_t read_u32_le(const unsigned char* data) {
    return (uint32_t)data[0] | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

static void write_u32_le(unsigned char* data, uint32_t value) {
    data[0] = (unsigned char)value;
    data[1] = (unsigned char)(value >> 8);
    data[2] = (unsigned char)(value >> 16);
    data[3] = (unsigned char)(value >> 24);
}

static int write_all(int fd, const unsigned char* data, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, data, length);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (written == 0)
            return -1;
        data += written;
        length -= (size_t)written;
    }
    return 0;
}

static int atomic_write(const char* path, const unsigned char* data, size_t length) {
    char temporary_path[PATH_MAX];
    int path_length = snprintf(temporary_path, sizeof(temporary_path), "%s.tmp", path);
    if (path_length <= 0 || path_length >= (int)sizeof(temporary_path))
        return -1;

    int fd = open(temporary_path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR);
    if (fd < 0)
        return -1;
    int failed =
        fchmod(fd, S_IRUSR | S_IWUSR) != 0 || write_all(fd, data, length) != 0 || fsync(fd) != 0;
    if (close(fd) != 0)
        failed = 1;
    if (failed || rename(temporary_path, path) != 0) {
        unlink(temporary_path);
        return -1;
    }
    return 0;
}

static int load_key(const char* path, unsigned char key[TOKEN_KEY_LENGTH]) {
    FILE* file = fopen(path, "rb");
    if (!file)
        return errno == ENOENT ? 0 : -1;
    size_t length = fread(key, 1, TOKEN_KEY_LENGTH, file);
    int extra = fgetc(file);
    int failed = ferror(file) || length != TOKEN_KEY_LENGTH || extra != EOF;
    fclose(file);
    return failed ? -1 : 1;
}

static int ensure_key(const char* path, unsigned char key[TOKEN_KEY_LENGTH]) {
    int result = load_key(path, key);
    if (result != 0)
        return result;
    if (RAND_bytes(key, TOKEN_KEY_LENGTH) != 1)
        return -1;
    return atomic_write(path, key, TOKEN_KEY_LENGTH) == 0 ? 1 : -1;
}

static int read_credential_file(const char* path, unsigned char** data, size_t* length) {
    FILE* file = fopen(path, "rb");
    if (!file)
        return errno == ENOENT ? 0 : -1;
    unsigned char* buffer = malloc(TOKEN_FILE_LIMIT);
    if (!buffer) {
        fclose(file);
        return -1;
    }
    size_t used = fread(buffer, 1, TOKEN_FILE_LIMIT, file);
    int failed = ferror(file) || (used == TOKEN_FILE_LIMIT && fgetc(file) != EOF);
    fclose(file);
    if (failed) {
        free(buffer);
        return -1;
    }
    *data = buffer;
    *length = used;
    return 1;
}

int go_token_store_load(const char* credential_path, const char* key_path, char* refresh_token,
                        size_t refresh_token_capacity) {
    unsigned char* file_data = NULL;
    size_t file_length = 0;
    int read_result = read_credential_file(credential_path, &file_data, &file_length);
    if (read_result <= 0)
        return read_result;

    const size_t header_length = 4 + 1 + 1 + TOKEN_NONCE_LENGTH + 4;
    if (file_length < header_length + TOKEN_TAG_LENGTH || memcmp(file_data, TOKEN_MAGIC, 4) != 0 ||
        file_data[4] != TOKEN_VERSION || file_data[5] != TOKEN_ENCRYPTED) {
        free(file_data);
        return -1;
    }

    uint32_t plaintext_length = read_u32_le(file_data + 6 + TOKEN_NONCE_LENGTH);
    if (plaintext_length > INT_MAX ||
        file_length != header_length + (size_t)plaintext_length + TOKEN_TAG_LENGTH) {
        free(file_data);
        return -1;
    }

    unsigned char key[TOKEN_KEY_LENGTH] = {0};
    if (load_key(key_path, key) != 1) {
        free(file_data);
        return -1;
    }
    unsigned char* plaintext = malloc(plaintext_length ? plaintext_length : 1);
    EVP_CIPHER_CTX* context = EVP_CIPHER_CTX_new();
    int output_length = 0;
    int final_length = 0;
    int ok = plaintext && context &&
             EVP_DecryptInit_ex(context, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1 &&
             EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, TOKEN_NONCE_LENGTH, NULL) == 1 &&
             EVP_DecryptInit_ex(context, NULL, NULL, key, file_data + 6) == 1 &&
             EVP_DecryptUpdate(context, plaintext, &output_length, file_data + header_length,
                               (int)plaintext_length) == 1 &&
             EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, TOKEN_TAG_LENGTH,
                                 file_data + header_length + plaintext_length) == 1 &&
             EVP_DecryptFinal_ex(context, plaintext + output_length, &final_length) == 1 &&
             output_length + final_length == (int)plaintext_length;

    int result = -1;
    if (ok && plaintext_length >= 8) {
        uint32_t access_length = read_u32_le(plaintext);
        if ((size_t)access_length <= plaintext_length - 8) {
            size_t refresh_offset = 4 + (size_t)access_length;
            uint32_t refresh_length = read_u32_le(plaintext + refresh_offset);
            refresh_offset += 4;
            if ((size_t)refresh_length == plaintext_length - refresh_offset &&
                (size_t)refresh_length < refresh_token_capacity) {
                memcpy(refresh_token, plaintext + refresh_offset, refresh_length);
                refresh_token[refresh_length] = '\0';
                result = 1;
            }
        }
    }

    EVP_CIPHER_CTX_free(context);
    if (plaintext) {
        OPENSSL_cleanse(plaintext, plaintext_length);
        free(plaintext);
    }
    OPENSSL_cleanse(key, sizeof(key));
    free(file_data);
    return result;
}

int go_token_store_save(const char* credential_path, const char* key_path,
                        const char* refresh_token) {
    size_t refresh_length = strlen(refresh_token);
    if (refresh_length > UINT32_MAX || refresh_length > INT_MAX - 8)
        return -1;
    size_t plaintext_length = 8 + refresh_length;
    unsigned char* plaintext = calloc(1, plaintext_length);
    if (!plaintext)
        return -1;
    write_u32_le(plaintext, 0);
    write_u32_le(plaintext + 4, (uint32_t)refresh_length);
    memcpy(plaintext + 8, refresh_token, refresh_length);

    unsigned char key[TOKEN_KEY_LENGTH] = {0};
    unsigned char nonce[TOKEN_NONCE_LENGTH];
    if (ensure_key(key_path, key) != 1 || RAND_bytes(nonce, sizeof(nonce)) != 1) {
        OPENSSL_cleanse(plaintext, plaintext_length);
        free(plaintext);
        OPENSSL_cleanse(key, sizeof(key));
        return -1;
    }

    const size_t header_length = 4 + 1 + 1 + TOKEN_NONCE_LENGTH + 4;
    size_t file_length = header_length + plaintext_length + TOKEN_TAG_LENGTH;
    unsigned char* file_data = calloc(1, file_length);
    EVP_CIPHER_CTX* context = EVP_CIPHER_CTX_new();
    if (!file_data || !context) {
        free(file_data);
        EVP_CIPHER_CTX_free(context);
        OPENSSL_cleanse(plaintext, plaintext_length);
        free(plaintext);
        OPENSSL_cleanse(key, sizeof(key));
        return -1;
    }
    memcpy(file_data, TOKEN_MAGIC, 4);
    file_data[4] = TOKEN_VERSION;
    file_data[5] = TOKEN_ENCRYPTED;
    memcpy(file_data + 6, nonce, sizeof(nonce));
    write_u32_le(file_data + 6 + TOKEN_NONCE_LENGTH, (uint32_t)plaintext_length);

    int output_length = 0;
    int final_length = 0;
    int ok = EVP_EncryptInit_ex(context, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1 &&
             EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, TOKEN_NONCE_LENGTH, NULL) == 1 &&
             EVP_EncryptInit_ex(context, NULL, NULL, key, nonce) == 1 &&
             EVP_EncryptUpdate(context, file_data + header_length, &output_length, plaintext,
                               (int)plaintext_length) == 1 &&
             EVP_EncryptFinal_ex(context, file_data + header_length + output_length,
                                 &final_length) == 1 &&
             output_length + final_length == (int)plaintext_length &&
             EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, TOKEN_TAG_LENGTH,
                                 file_data + header_length + plaintext_length) == 1;
    int result = ok ? atomic_write(credential_path, file_data, file_length) : -1;

    EVP_CIPHER_CTX_free(context);
    OPENSSL_cleanse(plaintext, plaintext_length);
    free(plaintext);
    OPENSSL_cleanse(key, sizeof(key));
    OPENSSL_cleanse(file_data, file_length);
    free(file_data);
    return result;
}
