using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ChildExitPin : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "child_exit_pin_hash",
                table: "families",
                type: "character varying(120)",
                maxLength: 120,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "exit_blocked_until",
                table: "child_devices",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "exit_failures",
                table: "child_devices",
                type: "integer",
                nullable: false,
                defaultValue: 0);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "child_exit_pin_hash",
                table: "families");

            migrationBuilder.DropColumn(
                name: "exit_blocked_until",
                table: "child_devices");

            migrationBuilder.DropColumn(
                name: "exit_failures",
                table: "child_devices");
        }
    }
}
