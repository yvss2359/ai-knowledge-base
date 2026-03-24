package com.akb.backend.dto.request;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.Data;

@Data
public class RegisterRequest {

    @NotBlank(message = "Email is required")
    @Email(message = "Email format not conform")
    private String email;

    @NotBlank(message = "Password is required")
    @Size(min = 8, message = "Password requires at least 8 characters")
    private String password;

    @NotBlank(message = "Full name is required")
    private String fullName;
}