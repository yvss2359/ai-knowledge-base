package com.akb.backend.service;

import com.akb.backend.dto.request.LoginRequest;
import com.akb.backend.dto.request.RegisterRequest;
import com.akb.backend.dto.response.AuthResponse;
import com.akb.backend.entity.User;
import com.akb.backend.repository.UserRepository;
import com.akb.backend.security.JwtService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;
    private final AuthenticationManager authenticationManager;

    @Transactional
    public AuthResponse register(RegisterRequest request) {

        // Checking if email already in use
        if (userRepository.existsByEmail(request.getEmail())) {
            throw new IllegalStateException(
                    "Account already using this email : " + request.getEmail()
            );
        }

        // Create User
        User user = User.builder()
                .email(request.getEmail())
                .passwordHash(passwordEncoder.encode(request.getPassword()))
                .fullName(request.getFullName())
                .isActive(true)
                .build();

        userRepository.save(user);

        // Generate Tokens
        String accessToken  = jwtService.generateToken(user);
        String refreshToken = jwtService.generateRefreshToken(user);

        return AuthResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .email(user.getEmail())
                .fullName(user.getFullName())
                .build();
    }

    public AuthResponse login(LoginRequest request) {

        // Spring Security checks the email and password (using BCrypt) and throws a BadCredentialsException if they are incorrect.
        authenticationManager.authenticate(
                new UsernamePasswordAuthenticationToken(
                        request.getEmail(),
                        request.getPassword()
                )
        );

        // If we reach this point, the credentials are valid
        User user = userRepository.findByEmail(request.getEmail())
                .orElseThrow();

        String accessToken  = jwtService.generateToken(user);
        String refreshToken = jwtService.generateRefreshToken(user);

        return AuthResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .email(user.getEmail())
                .fullName(user.getFullName())
                .build();
    }
}