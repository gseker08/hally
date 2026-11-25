using System;
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Hally.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class CaregiverAccess : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "access_until",
                table: "invitations",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "can_see_health",
                table: "invitations",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<List<Guid>>(
                name: "child_ids",
                table: "invitations",
                type: "uuid[]",
                nullable: false,
                defaultValueSql: "'{}'::uuid[]");

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "access_until",
                table: "family_members",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "can_see_health",
                table: "family_members",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<List<Guid>>(
                name: "child_ids",
                table: "family_members",
                type: "uuid[]",
                nullable: false,
                defaultValueSql: "'{}'::uuid[]");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "access_until",
                table: "invitations");

            migrationBuilder.DropColumn(
                name: "can_see_health",
                table: "invitations");

            migrationBuilder.DropColumn(
                name: "child_ids",
                table: "invitations");

            migrationBuilder.DropColumn(
                name: "access_until",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "can_see_health",
                table: "family_members");

            migrationBuilder.DropColumn(
                name: "child_ids",
                table: "family_members");
        }
    }
}
