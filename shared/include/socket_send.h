#ifndef _SOCKET_SEND_H_
#define _SOCKET_SEND_H_

#include <arpa/inet.h>	// htons(), ntohs()
#include <netdb.h>		// gethostbyname(), struct hostent
#include <netinet/in.h> // struct sockaddr_in
#include <stdio.h>		// perror(), fprintf()
#include <string.h>		// memcpy()
#include <sys/socket.h> // getsockname()
#include <unistd.h>		// stderr
#include "errno.h"
#include "constants.h"

// inline void tle_print(const char *str)
// {
// 	FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
// 	setvbuf(fptr, NULL, _IONBF, 0);
// 	fprintf(fptr, "%s\n", str);
// 	fclose(fptr);
// }

// inline void tle_print1(const char *str, int d)
// {
// 	FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
// 	setvbuf(fptr, NULL, _IONBF, 0);
// 	fprintf(fptr, "%s %d\n", str, d);
// 	fclose(fptr);
// }

// inline void tle_print3(const char *str, int a, int b, int c)
// {
// 	FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
// 	setvbuf(fptr, NULL, _IONBF, 0);
// 	fprintf(fptr, "%s %d %d %d\n", str, a, b, c);
// 	fclose(fptr);
// }

inline void tle_print_long(const char *str, unsigned long d)
{
	FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
	setvbuf(fptr, NULL, _IONBF, 0);
	fprintf(fptr, "%s %lu\n", str, d);
	fclose(fptr);
}

/**
 * Make a server sockaddr given a port.
 * Parameters:
 *		addr: 	The sockaddr to modify (this is a C-style function).
 *		port: 	The port on which to listen for incoming connections.
 * Returns:
 *		0 on success, -1 on failure.
 * Example:
 *		struct sockaddr_in server;
 *		int err = make_server_sockaddr(&server, 8888);
 */
inline int make_server_sockaddr(struct sockaddr_in *addr, int port)
{
	// Step (1): specify socket family.
	// This is an internet socket.
	addr->sin_family = AF_INET;

	// Step (2): specify socket address (hostname).
	// The socket will be a server, so it will only be listening.
	// Let the OS map it to the correct address.
	addr->sin_addr.s_addr = INADDR_ANY;

	// Step (3): Set the port value.
	// If port is 0, the OS will choose the port for us.
	// Use htons to convert from local byte order to network byte order.
	addr->sin_port = htons(port);

	return 0;
}

/**
 * Make a client sockaddr given a remote hostname and port.
 * Parameters:
 *		addr: 		The sockaddr to modify (this is a C-style function).
 *		hostname: 	The hostname of the remote host to connect to.
 *		port: 		The port to use to connect to the remote hostname.
 * Returns:
 *		0 on success, -1 on failure.
 * Example:
 *		struct sockaddr_in client;
 *		int err = make_client_sockaddr(&client, "141.88.27.42", 8888);
 */
inline int make_client_sockaddr(struct sockaddr_in *addr, const char *hostname, int port)
{
	// Step (1): specify socket family.
	// This is an internet socket.
	addr->sin_family = AF_INET;

	// Step (2): specify socket address (hostname).
	// The socket will be a client, so call this unix helper function
	// to convert a hostname string to a useable `hostent` struct.
	struct hostent *host = gethostbyname(hostname);
	if (host == NULL)
	{
		fprintf(stderr, "%s: unknown host\n", hostname);
		return -1;
	}
	memcpy(&(addr->sin_addr), host->h_addr, host->h_length);

	// Step (3): Set the port value.
	// Use htons to convert from local byte order to network byte order.
	addr->sin_port = htons(port);

	return 0;
}

/**
 * Return the port number assigned to a socket.
 *
 * Parameters:
 * 		sockfd:	File descriptor of a socket
 *
 * Returns:
 *		The port number of the socket, or -1 on failure.
 */
inline int get_port_number(int sockfd)
{
	struct sockaddr_in addr;
	socklen_t length = sizeof(addr);
	if (getsockname(sockfd, (struct sockaddr *)&addr, &length) == -1)
	{
		perror("Error getting port of socket");
		return -1;
	}
	// Use ntohs to convert from network byte order to host byte order.
	return ntohs(addr.sin_port);
}

/**
 * Sends a string message to the server.
 *
 * Parameters:
 *		hostname: 	Remote hostname of the server.
 *		port: 		Remote port of the server.
 * 		message: 	The message to send, as a C-string.
 * Returns:
 *		0 on success, -1 on failure.
 */
// inline int send_message(const char *hostname, int port, const char *message, const long unsigned message_length, int sock)
// {
// 	if (message_length > (MAX_MSG_LENGTH))
// 	{
// 		// tle_print("Message exceeds maximum length");
// 		return -1;
// 	}
// 	// Connect to remote server
// 	if (sock == -1)
// 	{
// 		struct addrinfo hints = {}, *addrs;
// 		char port_str[16] = {};

// 		hints.ai_family = AF_INET;
// 		hints.ai_socktype = SOCK_STREAM;
// 		hints.ai_protocol = IPPROTO_TCP;
// 		sprintf(port_str, "%d", port);

// 		if (getaddrinfo(hostname, port_str, &hints, &addrs) != 0)
// 		{
// 			// tle_print("Failed to get addr info");
// 		}

// 		for (struct addrinfo *addr = addrs; addr != NULL; addr = addr->ai_next)
// 		{
// 			sock = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
// 			if (sock == -1)
// 				break;

// 			if (!addr->ai_addr)
// 			{
// 				sock = -1;
// 				continue;
// 			}
// 			if (!addr->ai_addrlen)
// 			{
// 				sock = -1;
// 				continue;
// 			}
// 			if (connect(sock, addr->ai_addr, addr->ai_addrlen) == 0)
// 			{
// 				break;
// 			}

// 			close(sock);
// 			sock = -1;
// 		}
// 		freeaddrinfo(addrs);
// 		if (sock == -1)
// 		{
// 			// char buffer[ 256 ];
// 			// char *errorMsg = strerror_r( errno, buffer, 256 ); // GNU-specific version, Linux default
// 			// printf("Error %s\n", errorMsg); //return value has to be used since buffer might not be modified
// 			// throw std::runtime_error("Failed to connect\n");
// 			// tle_print("Error with socket resolution??\n");
// 		}
// 	}
// 	if (sock == -1 || !message || !message_length)
// 	{
// 		// tle_print("Missed something on send");
// 	}
// 	// Send message to remote server
// 	if (send(sock, message, message_length, 0) == -1)
// 	{
// 		tle_print("Error sending on stream socket");
// 	}

// 	return sock;
// }

#endif